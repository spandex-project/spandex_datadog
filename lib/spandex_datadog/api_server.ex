defmodule SpandexDatadog.ApiServer do
  @moduledoc """
  Implements worker for sending spans to datadog as GenServer in order to send traces async.
  """

  @behaviour :gen_statem

  require Logger

  alias Spandex.{Span, Trace}
  alias SpandexDatadog.Formatter

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            send_interval: non_neg_integer(),
            export_timeout: non_neg_integer(),
            runner_pid: pid(),
            handed_off_table: :ets.tab(),
            max_queue_size: non_neg_integer(),
            size_check_interval: non_neg_integer(),
            http: atom(),
            url: String.t(),
            host: String.t(),
            port: non_neg_integer(),
            verbose?: boolean()
          }

    defstruct [
      :send_interval,
      :export_timeout,
      :runner_pid,
      :handed_off_table,
      :max_queue_size,
      :size_check_interval,
      :http,
      :url,
      :host,
      :port,
      :verbose?
    ]
  end

  # Same as HTTPoison.headers
  @type headers :: [{atom(), binary()}] | [{binary(), binary()}] | %{binary() => binary()} | any()

  @headers [{"Content-Type", "application/msgpack"}]

  @current_table_key {__MODULE__, :current_table}
  @table_1 :"#{__MODULE__}-1"
  @table_2 :"#{__MODULE__}-2"

  @enabled_key {__MODULE__, :enabled}

  # https://github.com/DataDog/datadog-agent/blob/fa227f0015a5da85617e8af30778fcfc9521e568/pkg/trace/api/api.go#L46
  @dd_limit 10 * 1024 * 1024

  @ets_batch 100

  @start_link_opts Optimal.schema(
                     opts: [
                       host: :string,
                       port: [:integer, :string],
                       verbose?: :boolean,
                       http: :atom,
                       api_adapter: :atom,
                       max_queue_size: :integer,
                       send_interval: :integer,
                       export_timeout: :integer,
                       size_check_interval: :integer,
                       sync_threshold: :integer,
                       batch_size: :integer
                     ],
                     defaults: [
                       host: "localhost",
                       port: 8126,
                       verbose?: false,
                       api_adapter: SpandexDatadog.ApiServer,
                       max_queue_size: 20 * 1024 * 1024,
                       send_interval: :timer.seconds(2),
                       export_timeout: :timer.minutes(1),
                       size_check_interval: 500
                     ],
                     required: [:http],
                     describe: [
                       verbose?: "Only to be used for debugging: All finished traces will be logged",
                       host: "The host the agent can be reached at",
                       port: "The port to use when sending traces to the agent",
                       http:
                         "The HTTP module to use for sending spans to the agent. Currently only HTTPoison has been tested",
                       api_adapter: "Which api adapter to use. Currently only used for testing",
                       send_interval: "Interval for sending a batch",
                       export_timeout: "Timeout to allow each export operation to run",
                       size_check_interval: "Interval to check the size of the buffer",
                       sync_threshold: "depreciated",
                       batch_size: "depreciated"
                     ]
                   )

  # Public Functions

  defdelegate format(trace_or_span), to: Formatter
  defdelegate format(span, priority, baggage), to: Formatter

  def child_spec(opts) do
    %{
      id: __MODULE__,
      type: :worker,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts server with given options.

  #{Optimal.Doc.document(@start_link_opts)}
  """
  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Optimal.validate!(opts, @start_link_opts)

    case Keyword.get(opts, :name) do
      nil ->
        :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])

      name ->
        :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
    end
  end

  def callback_mode do
    [:state_functions, :state_enter]
  end

  @doc """
  Send spans asynchronously to DataDog.
  """
  @spec send_trace(Trace.t(), Keyword.t()) :: :ok
  def send_trace(%Trace{} = trace, _opts \\ []) do
    :telemetry.span([:spandex_datadog, :insert_trace], %{trace: trace}, fn ->
      result = do_insert(trace)
      {result, %{trace: trace}}
    end)
  end

  @deprecated "Please use send_trace/2 instead"
  @doc false
  @spec send_spans([Span.t()], Keyword.t()) :: :ok
  def send_spans(spans, _opts \\ []) when is_list(spans) do
    trace = %Trace{spans: spans}
    do_insert(trace)
  end

  def enable do
    Logger.info("%{__MODULE__} is enabled")
    :persistent_term.put(@enabled_key, true)
  end

  def disable do
    Logger.info("%{__MODULE__} is disabled")
    :persistent_term.put(@enabled_key, false)
  end

  def is_enabled do
    :persistent_term.get(@enabled_key, true)
  end

  # Callbacks

  def init(opts) do
    Process.flag(:trap_exit, true)

    _tid1 = new_export_table(@table_1)
    _tid2 = new_export_table(@table_2)
    :persistent_term.put(@current_table_key, @table_1)

    enable()

    {:ok, :idle,
     %State{
       host: opts[:host],
       port: opts[:port],
       verbose?: opts[:verbose?],
       http: opts[:http],
       handed_off_table: :undefined,
       max_queue_size: opts[:max_queue_size],
       export_timeout: opts[:export_timeout],
       size_check_interval: opts[:size_check_interval],
       send_interval: opts[:send_interval]
     }}
  end

  def idle(
        :enter,
        _old_state,
        %State{send_interval: send_interval, size_check_interval: size_check_interval} = state
      ) do
    if state.verbose?, do: Logger.debug("idle(:enter, _, _)")

    actions = [
      {{:timeout, :export_spans}, send_interval, :export_spans},
      {{:timeout, :check_table_size}, size_check_interval, :check_table_size}
    ]

    {:keep_state_and_data, actions}
  end

  def idle(_, :export_spans, state) do
    if state.verbose?, do: Logger.debug("idle(_, :export_spans, _)")
    {:next_state, :exporting, state}
  end

  def idle(event_type, event, state) do
    if state.verbose?, do: Logger.debug("idle/3")
    handle_event_(:idle, event_type, event, state)
  end

  def exporting({:timeout, :export_spans}, :export_spans, state) do
    if state.verbose?, do: Logger.debug("exporting({:timeout, :export_spans}, :export_spans, _)")
    {:keep_state_and_data, [:postpone]}
  end

  def exporting(
        :enter,
        _old_state,
        %State{
          export_timeout: exporting_timeout,
          send_interval: send_interval,
          size_check_interval: size_check_interval
        } = state
      ) do
    if state.verbose?, do: Logger.debug("exporting(:enter, _, _)")
    {old_table_name, runner_pid} = export_spans(state)

    actions = [
      {:state_timeout, exporting_timeout, :exporting_timeout},
      {{:timeout, :export_spans}, send_interval, :export_spans},
      {{:timeout, :check_table_size}, size_check_interval, :check_table_size}
    ]

    {:keep_state, %State{state | runner_pid: runner_pid, handed_off_table: old_table_name}, actions}
  end

  def exporting(:state_timeout, :exporting_timeout, %State{handed_off_table: exporting_table} = state) do
    if state.verbose?, do: Logger.debug("exporting(:state_timeout, _, _)")
    # kill current exporting process because it is taking too long
    # which deletes the exporting table, so create a new one and
    # repeat the state to force another span exporting immediately
    state = kill_runner(state)
    new_export_table(exporting_table)
    {:repeat_state, state}
  end

  # important to verify runner_pid and from_pid are the same in case it was sent
  # after kill_runner was called but before it had done the unlink
  def exporting(:info, {:EXIT, from_pid, _}, %State{runner_pid: from_pid} = state) do
    if state.verbose?, do: Logger.debug("exporting(:info, {:EXIT, _, _}, _)")
    complete_exporting(state)
  end

  # important to verify runner_pid and from_pid are the same in case it was sent
  # after kill_runner was called but before it had done the unlink
  def exporting(:info, {:completed, from_pid}, %State{runner_pid: from_pid} = state) do
    if state.verbose?, do: Logger.debug("exporting(:info, {:completed, _}, _)")
    complete_exporting(state)
  end

  def exporting(event_type, event, state) do
    if state.verbose?, do: Logger.debug("exporting/3")
    handle_event_(:exporting, event_type, event, state)
  end

  def terminate(_, _, state) do
    if state.verbose?, do: Logger.debug("terminate/3")
    # TODO: flush buffers to export
    :ok
  end

  # Private Functions

  defp handle_event_(_state, {:timeout, :check_table_size}, :check_table_size, %State{max_queue_size: :infinity}) do
    :keep_state_and_data
  end

  defp handle_event_(_state, {:timeout, :check_table_size}, :check_table_size, %State{
         max_queue_size: max_queue_size
       }) do
    tab_memory = :ets.info(current_table(), :memory)
    tab_size = :ets.info(current_table(), :size)
    bytes = tab_memory * :erlang.system_info(:wordsize)
    :telemetry.execute([:spandex_datadog, :buffer, :info], %{bytes: bytes, items: tab_size})

    case bytes do
      m when m >= max_queue_size ->
        disable()
        :keep_state_and_data

      _ ->
        enable()
        :keep_state_and_data
    end
  end

  defp handle_event_(_, _, _, _) do
    :keep_state_and_data
  end

  defp do_insert(trace) do
    try do
      case is_enabled() do
        true ->
          :telemetry.execute([:spandex_datadog, :insert_trace, :inserted], %{})
          :ets.insert(current_table(), {System.monotonic_time(), trace})

        _ ->
          :telemetry.execute([:spandex_datadog, :insert_trace, :dropped], %{})
          :dropped
      end
    catch
      :error, :badarg ->
        {:error, :no_batch_span_processor}

      _, _ ->
        {:error, :other}
    end
  end

  defp complete_exporting(%State{handed_off_table: exporting_table} = state) when exporting_table != :undefined do
    new_export_table(exporting_table)
    {:next_state, :idle, %State{state | runner_pid: :undefined, handed_off_table: :undefined}}
  end

  defp kill_runner(%State{runner_pid: runner_pid} = state) do
    :erlang.unlink(runner_pid)
    :erlang.exit(:runner_pid, :kill)
    %State{state | runner_pid: :undefined, handed_off_table: :undefined}
  end

  defp new_export_table(name) do
    :ets.new(name, [:public, :named_table, {:write_concurrency, true}, :duplicate_bag])
  end

  defp current_table do
    :persistent_term.get(@current_table_key)
  end

  defp export_spans(%State{} = state) do
    current_table = current_table()

    new_current_table =
      case current_table do
        @table_1 -> @table_2
        @table_2 -> @table_1
      end

    # an atom is a single word so this does not trigger a global GC
    :persistent_term.put(@current_table_key, new_current_table)
    # set the table to accept inserts
    enable()

    self = self()
    runner_pid = :erlang.spawn_link(fn -> do_send_spans(self, state) end)
    :ets.give_away(current_table, runner_pid, :export)
    {current_table, runner_pid}
  end

  # Additional benefit of using a separate process is calls to `register` won't
  # timeout if the actual exporting takes longer than the call timeout
  defp do_send_spans(from_pid, state) do
    receive do
      {:"ETS-TRANSFER", table, ^from_pid, :export} ->
        table_name = :ets.rename(table, :current_send_table)
        export(table_name, state)
        :ets.delete(table_name)
        completed(from_pid)
    end
  end

  defp completed(from_pid) do
    send(from_pid, {:completed, self()})
  end

  defp export(trace_table, state) do
    # don't let a export exception crash us
    # and return true if export failed
    try do
      Stream.resource(fn -> stream_start(trace_table) end, &stream_next/1, &stream_after/1)
      |> Stream.map(&format_trace/1)
      |> Stream.map(&Msgpax.pack_fragment!/1)
      # One byte overhead for msgpack and one byte for the first entry
      |> Stream.chunk_while({[], 0, 2}, &stream_chunk/2, &stream_chunk_after/1)
      |> Stream.map(&{length(&1), Msgpax.pack!(&1)})
      |> Stream.map(fn {count, payload} ->
        :telemetry.span([:spandex_datadog, :send_traces], %{events: count}, fn ->
          headers = @headers ++ [{"X-Datadog-Trace-Count", count}]
          res = push(payload, headers, state)

          if state.verbose?, do: Logger.debug("push_result: #{inspect(res)}")

          {true, %{events: count}}
        end)

        :ok
      end)
      |> Stream.run()

      true
    catch
      e ->
        Logger.error("export threw exception: #{inspect(e)}")
        true
    end
  end

  defp stream_start(trace_table) do
    :ets.select(trace_table, [{{:"$1", :"$2"}, [], [:"$2"]}], @ets_batch)
  end

  defp stream_next(:"$end_of_table"), do: {:halt, :ok}
  defp stream_next({:continue, continuation}), do: {[], :ets.select(continuation)}
  defp stream_next({traces, continuation}), do: {traces, {:continue, continuation}}

  defp stream_after(_), do: :ok

  defp format_trace(%Trace{spans: spans, priority: priority, baggage: baggage}) do
    Enum.map(spans, &Formatter.format(&1, priority, baggage))
  end

  defp stream_chunk(fragment, {acc, cur_len, overhead}) do
    case IO.iodata_length(fragment.data) do
      length when length + overhead > @dd_limit ->
        {:cont, {acc, cur_len}, overhead}

      length when length + overhead + cur_len > @dd_limit ->
        {:cont, acc, {[fragment], length, 2}}

      length ->
        {:cont, {[fragment | acc], cur_len + length, overhead + 1}}
    end
  end

  defp stream_chunk_after({[], _, _}), do: {:cont, {[], 0, 2}}
  defp stream_chunk_after({acc, _, _}), do: {:cont, Enum.reverse(acc), {[], 0, 2}}

  @spec push(body :: iodata(), headers, State.t()) :: any()
  defp push(body, headers, %State{http: http, host: host, port: port}),
    do: http.put("#{host}:#{port}/v0.3/traces", body, headers)
end
