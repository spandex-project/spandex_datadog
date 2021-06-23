defmodule SpandexDatadog.ApiServer do
  @moduledoc """
  Implements worker for sending spans to datadog as GenServer in order to send traces async.
  """

  @behaviour :gen_statem

  require Logger

  alias Spandex.{Span, Trace}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            scheduled_delay_ms: non_neg_integer(),
            exporting_timeout_ms: non_neg_integer(),
            runner_pid: pid(),
            handed_off_table: :ets.tab(),
            max_queue_size: non_neg_integer(),
            check_table_size_ms: non_neg_integer(),
            http: atom(),
            url: String.t(),
            host: String.t(),
            port: non_neg_integer(),
            verbose?: boolean()
          }

    defstruct [
      :scheduled_delay_ms,
      :exporting_timeout_ms,
      :runner_pid,
      :handed_off_table,
      :max_queue_size,
      :check_table_size_ms,
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

  @start_link_opts Optimal.schema(
                     opts: [
                       host: :string,
                       port: [:integer, :string],
                       verbose?: :boolean,
                       http: :atom,
                       api_adapter: :atom,
                       max_queue_size: :integer,
                       scheduled_delay_ms: :integer,
                       export_timeout_ms: :integer,
                       check_table_size_ms: :integer,
                       sync_threshold: :integer,
                       batch_size: :integer
                     ],
                     defaults: [
                       host: "localhost",
                       port: 8126,
                       verbose?: false,
                       api_adapter: SpandexDatadog.ApiServer,
                       max_queue_size: 20 * 1024 * 1024,
                       scheduled_delay_ms: :timer.seconds(5),
                       export_timeout_ms: :timer.minutes(5),
                       check_table_size_ms: :timer.seconds(1)
                     ],
                     required: [:http],
                     describe: [
                       verbose?: "Only to be used for debugging: All finished traces will be logged",
                       host: "The host the agent can be reached at",
                       port: "The port to use when sending traces to the agent",
                       http:
                         "The HTTP module to use for sending spans to the agent. Currently only HTTPoison has been tested",
                       api_adapter: "Which api adapter to use. Currently only used for testing",
                       scheduled_delay_ms: "Interval for sending a batch",
                       export_timeout_ms: "Timeout to allow each export operation to run",
                       check_table_size_ms: "Interval to check the size of the buffer",
                       sync_threshold: "depreciated",
                       batch_size: "depreciated"
                     ]
                   )

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
       exporting_timeout_ms: opts[:export_timeout_ms],
       check_table_size_ms: opts[:check_table_size_ms],
       scheduled_delay_ms: opts[:scheduled_delay_ms]
     }}
  end

  def idle(
        :enter,
        _old_state,
        %State{scheduled_delay_ms: send_interval, check_table_size_ms: size_check_interval} = state
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
          exporting_timeout_ms: exporting_timeout,
          scheduled_delay_ms: send_interval,
          check_table_size_ms: size_check_interval
        } = state
      ) do
    if state.verbose?, do: Logger.debug("exporting(:enter, _, _)")
    {old_table_name, runner_pid} = export_spans(state)

    Logger.debug("After Export Spans")

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

  def handle_event_(_state, {:timeout, :check_table_size}, :check_table_size, %State{max_queue_size: :infinity}) do
    :keep_state_and_data
  end

  def handle_event_(_state, {:timeout, :check_table_size}, :check_table_size, %State{
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

  def handle_event_(_, _, _, _) do
    :keep_state_and_data
  end

  def terminate(_, _, state) do
    if state.verbose?, do: Logger.debug("terminate/3")
    # TODO: flush buffers to export
    :ok
  end

  def enable do
    Logger.debug("%{__MODULE__} is enabled")
    :persistent_term.put(@enabled_key, true)
  end

  def disable do
    Logger.debug("%{__MODULE__} is disabled")
    :persistent_term.put(@enabled_key, false)
  end

  def is_enabled do
    :persistent_term.get(@enabled_key, true)
  end

  def do_insert(trace) do
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

  def complete_exporting(%State{handed_off_table: exporting_table} = state) when exporting_table != :undefined do
    new_export_table(exporting_table)
    {:next_state, :idle, %State{state | runner_pid: :undefined, handed_off_table: :undefined}}
  end

  def kill_runner(%State{runner_pid: runner_pid} = state) do
    :erlang.unlink(runner_pid)
    :erlang.exit(:runner_pid, :kill)
    %State{state | runner_pid: :undefined, handed_off_table: :undefined}
  end

  def new_export_table(name) do
    :ets.new(name, [:public, :named_table, {:write_concurrency, true}, :duplicate_bag])
  end

  def current_table do
    :persistent_term.get(@current_table_key)
  end

  def export_spans(%State{} = state) do
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
  def do_send_spans(from_pid, state) do
    receive do
      {:"ETS-TRANSFER", table, ^from_pid, :export} ->
        table_name = :ets.rename(table, :current_send_table)
        export(table_name, state)
        :ets.delete(table_name)
        completed(from_pid)
    end
  end

  def completed(from_pid) do
    send(from_pid, {:completed, self()})
  end

  def export(trace_tid, state) do
    # don't let a export exception crash us
    # and return true if export failed
    try do
      trace_tid
      |> :ets.select([{{:"$1", :"$2"}, [], [:"$2"]}])
      |> Enum.map(&format/1)
      |> Enum.map(&deep_remove_nils/1)
      |> Enum.map(&Msgpax.pack_fragment!/1)
      |> chunk_events()
      |> Enum.each(fn chunk ->
        len = length(chunk)

        :telemetry.span([:spandex_datadog, :send_traces], %{events: len}, fn ->
          headers = @headers ++ [{"X-Datadog-Trace-Count", len}]
          payload = Msgpax.pack!(chunk)
          res = push(payload, headers, state)

          if state.verbose?, do: Logger.debug("push_result: #{inspect(res)}")

          {true, %{events: len}}
        end)
      end)

      true
    catch
      e ->
        Logger.error("export threw exception: #{inspect(e)}")
        true
    end
  end

  @spec push(body :: iodata(), headers, State.t()) :: any()
  defp push(body, headers, %State{http: http, host: host, port: port}),
    do: http.put("#{host}:#{port}/v0.3/traces", body, headers)

  def chunk_events(events) do
    {chunks, _} =
      Enum.reduce(events, {[[]], 0}, fn event, {[curr_chunk | rest] = payloads, curr_length} ->
        case IO.iodata_length(event.data) do
          length when length > @dd_limit ->
            {payloads, curr_length}

          length when length + curr_length > @dd_limit ->
            {[[event], curr_chunk | rest], length}

          length ->
            {[[event | curr_chunk] | rest], curr_length + length}
        end
      end)

    case chunks do
      [[]] ->
        []

      chunks ->
        chunks
        |> Enum.map(&Enum.reverse/1)
        |> Enum.reverse()
    end
  end

  @deprecated "Please use format/3 instead"
  @spec format(Trace.t()) :: map()
  def format(%Trace{spans: spans, priority: priority, baggage: baggage}) do
    Enum.map(spans, fn span -> format(span, priority, baggage) end)
  end

  @deprecated "Please use format/3 instead"
  @spec format(Span.t()) :: map()
  def format(%Span{} = span), do: format(span, 1, [])

  @spec format(Span.t(), integer(), Keyword.t()) :: map()
  def format(%Span{} = span, priority, _baggage) do
    %{
      trace_id: span.trace_id,
      span_id: span.id,
      name: span.name,
      start: span.start,
      duration: (span.completion_time || SpandexDatadog.Adapter.now()) - span.start,
      parent_id: span.parent_id,
      error: error(span.error),
      resource: span.resource || span.name,
      service: span.service,
      type: span.type,
      meta: meta(span),
      metrics:
        metrics(span, %{
          _sampling_priority_v1: priority
        })
    }
  end

  @spec error(nil | Keyword.t()) :: integer
  defp error(nil), do: 0

  defp error(keyword) do
    if Enum.any?(keyword, fn {_, v} -> not is_nil(v) end) do
      1
    else
      0
    end
  end

  @spec meta(Span.t()) :: map
  defp meta(span) do
    %{}
    |> add_datadog_meta(span)
    |> add_error_data(span)
    |> add_http_data(span)
    |> add_sql_data(span)
    |> add_tags(span)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  @spec add_datadog_meta(map, Span.t()) :: map
  defp add_datadog_meta(meta, %Span{env: nil}), do: meta

  defp add_datadog_meta(meta, %Span{env: env}) do
    Map.put(meta, :env, env)
  end

  @spec add_error_data(map, Span.t()) :: map
  defp add_error_data(meta, %{error: nil}), do: meta

  defp add_error_data(meta, %{error: error}) do
    meta
    |> add_error_type(error[:exception])
    |> add_error_message(error[:exception])
    |> add_error_stacktrace(error[:stacktrace])
  end

  @spec add_error_type(map, Exception.t() | nil) :: map
  defp add_error_type(meta, nil), do: meta
  defp add_error_type(meta, exception), do: Map.put(meta, "error.type", exception.__struct__)

  @spec add_error_message(map, Exception.t() | nil) :: map
  defp add_error_message(meta, nil), do: meta

  defp add_error_message(meta, exception),
    do: Map.put(meta, "error.msg", Exception.message(exception))

  @spec add_error_stacktrace(map, list | nil) :: map
  defp add_error_stacktrace(meta, nil), do: meta

  defp add_error_stacktrace(meta, stacktrace),
    do: Map.put(meta, "error.stack", Exception.format_stacktrace(stacktrace))

  @spec add_http_data(map, Span.t()) :: map
  defp add_http_data(meta, %{http: nil}), do: meta

  defp add_http_data(meta, %{http: http}) do
    status_code =
      if http[:status_code] do
        to_string(http[:status_code])
      end

    meta
    |> Map.put("http.url", http[:url])
    |> Map.put("http.status_code", status_code)
    |> Map.put("http.method", http[:method])
  end

  @spec add_sql_data(map, Span.t()) :: map
  defp add_sql_data(meta, %{sql_query: nil}), do: meta

  defp add_sql_data(meta, %{sql_query: sql}) do
    meta
    |> Map.put("sql.query", sql[:query])
    |> Map.put("sql.rows", sql[:rows])
    |> Map.put("sql.db", sql[:db])
  end

  @spec add_tags(map, Span.t()) :: map
  defp add_tags(meta, %{tags: nil}), do: meta

  defp add_tags(meta, %{tags: tags}) do
    tags = tags |> Keyword.delete(:analytics_event)

    Map.merge(
      meta,
      tags
      |> Enum.map(fn {k, v} -> {k, term_to_string(v)} end)
      |> Enum.into(%{})
    )
  end

  @spec metrics(Span.t(), map) :: map
  defp metrics(span, initial_value = %{}) do
    initial_value
    |> add_metrics(span)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  @spec add_metrics(map, Span.t()) :: map
  defp add_metrics(metrics, %{tags: nil}), do: metrics

  defp add_metrics(metrics, %{tags: tags}) do
    with analytics_event <- tags |> Keyword.get(:analytics_event),
         true <- analytics_event != nil do
      Map.merge(
        metrics,
        %{"_dd1.sr.eausr" => 1}
      )
    else
      _ ->
        metrics
    end
  end

  @spec deep_remove_nils(term) :: term
  defp deep_remove_nils(term) when is_map(term) do
    term
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    |> Enum.into(%{})
  end

  defp deep_remove_nils(term) when is_list(term) do
    if Keyword.keyword?(term) do
      term
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    else
      Enum.map(term, &deep_remove_nils/1)
    end
  end

  defp deep_remove_nils(term), do: term

  defp term_to_string(term) when is_binary(term), do: term
  defp term_to_string(term) when is_atom(term), do: term
  defp term_to_string(term), do: inspect(term)
end
