defmodule SpandexDatadog.ApiServer do
  @moduledoc """
  Implements worker for sending spans to datadog as GenServer in order to send traces async.
  """

  use GenServer
  require Logger

  alias Spandex.{
    Span,
    Trace
  }

  defmodule State do
    @moduledoc false

    @type t :: %State{}

    defstruct [
      :asynchronous_send?,
      :http,
      :url,
      :host,
      :port,
      :verbose?,
      :waiting_traces,
      :batch_size,
      :sync_threshold,
      :agent_pid,
      :container_id,
      :trap_exits?
    ]
  end

  # Same as HTTPoison.headers
  @type headers :: [{atom, binary}] | [{binary, binary}] | %{binary => binary} | any

  @headers [
    {"Content-Type", "application/msgpack"},
    {"Datadog-Meta-Lang", "elixir"},
    {"Datadog-Meta-Lang-Version", System.version()},
    {"Datadog-Meta-Tracer-Version", Application.spec(:spandex_datadog)[:vsn]}
  ]

  @default_opts [
    host: "localhost",
    http: HTTPoison,
    port: 8126,
    verbose?: false,
    batch_size: 10,
    sync_threshold: 20,
    asynchronous_send?: true,
    trap_exits?: false,
    name: __MODULE__,
    api_adapter: SpandexDatadog.ApiServer
  ]

  @doc """
  Starts the ApiServer with given options.

  ## Options

  * `:http` - The HTTP module to use for sending spans to the agent. Defaults to `HTTPoison`.
  * `:host` - The host the agent can be reached at. Defaults to `"localhost"`.
  * `:port` - The port to use when sending traces to the agent. Defaults to `8126`.
  * `:verbose?` - Only to be used for debugging: All finished traces will be logged. Defaults to `false`
  * `:batch_size` - The number of traces that should be sent in a single batch. Defaults to `10`.
  * `:sync_threshold` - The maximum number of processes that may be sending traces at any one time. This adds backpressure. Defaults to `20`.
  * `:name` - The name the GenServer should have. Currently only used for testing. Defaults to `SpandexDatadog.ApiServer`
  * `:trap_exits?` - Whether or not to trap exits and attempt to flush traces on shutdown, defaults to `false`. Useful if you do frequent deploys and you don't want to lose traces each deploy.
  * `:asynchronous_send?` - Whether or not to send traces asynchronously. Defaults to `true`. Should really only ever be set to `false` in some tests.
  """
  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec init(opts :: Keyword.t()) :: {:ok, State.t()}
  def init(opts) do
    if opts[:trap_exits?] do
      Process.flag(:trap_exit, true)
    end

    {:ok, agent_pid} =
      Agent.start_link(fn ->
        %{
          unsynced_traces: 0,
          sampling_rates: nil
        }
      end)

    state = %State{
      host: opts[:host],
      port: opts[:port],
      verbose?: opts[:verbose?],
      http: opts[:http],
      waiting_traces: [],
      batch_size: opts[:batch_size],
      sync_threshold: opts[:sync_threshold],
      asynchronous_send?: opts[:asynchronous_send?],
      agent_pid: agent_pid,
      container_id: get_container_id()
    }

    {:ok, state}
  end

  @cgroup_uuid "[0-9a-f]{8}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{12}"
  @cgroup_ctnr "[0-9a-f]{64}"
  @cgroup_task "[0-9a-f]{32}-\\d+"
  @cgroup_regex Regex.compile!(".*(#{@cgroup_uuid}|#{@cgroup_ctnr}|#{@cgroup_task})(?:\\.scope)?$", "m")

  defp get_container_id() do
    with {:ok, file_binary} <- File.read("/proc/self/cgroup"),
         [_, container_id] <- Regex.run(@cgroup_regex, file_binary) do
      container_id
    else
      _ -> nil
    end
  end

  @doc """
  Send spans asynchronously to DataDog.
  """
  @spec send_trace(Trace.t(), Keyword.t()) :: :ok
  def send_trace(%Trace{} = trace, opts \\ []) do
    :telemetry.span([:spandex_datadog, :send_trace], %{trace: trace}, fn ->
      timeout = Keyword.get(opts, :timeout, 30_000)
      genserver_name = Keyword.get(opts, :name, __MODULE__)
      result = GenServer.call(genserver_name, {:send_trace, trace}, timeout)
      {result, %{trace: trace}}
    end)
  end

  @deprecated "Please use send_trace/2 instead"
  @doc false
  @spec send_spans([Span.t()], Keyword.t()) :: :ok
  def send_spans(spans, opts \\ []) when is_list(spans) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    trace = %Trace{spans: spans}
    genserver_name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(genserver_name, {:send_trace, trace}, timeout)
  end

  def get_sampling_rates(opts \\ []) do
    genserver_name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(genserver_name, :get_sampling_rates)
  end

  def handle_call(:get_sampling_rates, _from, state) do
    sampling_rates = Agent.get(state.agent_pid, fn agent_state -> agent_state.sampling_rates end)

    {:reply, sampling_rates, state}
  end

  @doc false
  def handle_call({:send_trace, trace}, _from, state) do
    state =
      state
      |> enqueue_trace(trace)
      |> maybe_flush_traces()

    {:reply, :ok, state}
  end

  @doc false
  def handle_info({:EXIT, _pid, reason}, state) do
    terminate(reason, state)
    {:noreply, %State{state | waiting_traces: []}}
  end

  @doc false
  def terminate(_reason, state) do
    # set batch_size to 0 to force any remaining traces to be flushed
    # set asynchronous_send? to false to send the last traces synchronously
    state
    |> Map.put(:batch_size, 0)
    |> Map.put(:asynchronous_send?, false)
    |> maybe_flush_traces()

    :ok
  end

  @spec send_and_log([Trace.t()], State.t()) :: :ok
  def send_and_log(traces, _state) when length(traces) < 1 do
    # no-op if there's no traces to send
    :ok
  end

  def send_and_log(traces, %{container_id: container_id, verbose?: verbose?} = state) do
    headers = @headers ++ [{"X-Datadog-Trace-Count", length(traces)}]
    headers = headers ++ List.wrap(if container_id, do: {"Datadog-Container-ID", container_id})

    response =
      traces
      |> Enum.map(&format/1)
      |> encode()
      |> push(headers, state)

    with {:ok, %{status_code: 200, body: body}} <- response,
         {:ok, sampling_rates} <- Jason.decode(body) do
      Agent.update(state.agent_pid, fn agent_state ->
        Map.put(agent_state, :sampling_rates, sampling_rates["rate_by_service"])
      end)
    else
      _ -> Logger.warn(fn -> "Failed to send traces and update the sampling rates: #{inspect(response)}" end)
    end

    if verbose? do
      Logger.debug(fn -> "Trace response: #{inspect(response)}" end)
    end

    :ok
  end

  @deprecated "Please use format/3 instead"
  @doc false
  @spec format(Trace.t()) :: map()
  def format(%Trace{spans: spans, sampling: sampling, baggage: baggage}) do
    Enum.map(spans, fn span -> format(span, sampling, baggage) end)
  end

  @deprecated "Please use format/3 instead"
  @doc false
  @spec format(Span.t()) :: map()
  def format(%Span{} = span), do: format(span, 1, [])

  @spec format(Span.t(), integer(), Keyword.t()) :: map()
  def format(%Span{} = span, sampling, _baggage) do
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
      meta:
        %{
          "sql.query" => get_in(span, [Access.key(:sql_query), :query]),
          "sql.rows" => get_in(span, [Access.key(:sql_query), :rows]),
          "sql.db" => get_in(span, [Access.key(:sql_query), :db]),
          "http.url" => get_in(span, [Access.key(:http), :url]),
          "http.method" => get_in(span, [Access.key(:http), :method]),
          "http.status_code" =>
            case get_in(span, [Access.key(:http), :status_code]) do
              nil -> nil
              status_code -> to_string(status_code)
            end,
          "error.type" =>
            case get_in(span, [Access.key(:error), :exception]) do
              nil -> nil
              %exception{} -> exception
            end,
          "error.msg" =>
            case get_in(span, [Access.key(:error), :exception]) do
              nil -> nil
              exception -> Exception.message(exception)
            end,
          "error.stack" =>
            case get_in(span, [Access.key(:error), :stacktrace]) do
              nil -> nil
              stacktrace -> Exception.format_stacktrace(stacktrace)
            end,
          "_dd.p.dm" =>
            case sampling[:sampling_mechanism_used] do
              nil -> nil
              mechanism -> to_string(mechanism)
            end,
          env: span.env,
          version: span.service_version
        }
        |> add_analytics_sample_rate(span)
        |> add_tags(span),
      metrics: %{
        "_sampling_priority_v1" => sampling[:priority]
      } |> Map.merge(sampling_rate_used_params(sampling))
    }
  end

  # Private Helpers

  defp enqueue_trace(state, trace) do
    if state.verbose? do
      Logger.info(fn -> "Adding trace to stack with #{Enum.count(trace.spans)} spans" end)
    end

    %State{state | waiting_traces: [trace | state.waiting_traces]}
  end

  defp maybe_flush_traces(%{waiting_traces: traces, batch_size: size} = state) when length(traces) < size do
    state
  end

  defp maybe_flush_traces(state) do
    %{
      asynchronous_send?: async?,
      verbose?: verbose?,
      waiting_traces: traces
    } = state

    if verbose? do
      span_count = Enum.reduce(traces, 0, fn trace, acc -> acc + length(trace.spans) end)
      Logger.info(fn -> "Sending #{length(traces)} traces, #{span_count} spans." end)
      Logger.debug(fn -> "Trace: #{inspect(traces)}" end)
    end

    if async? do
      if below_sync_threshold?(state) do
        Task.start(fn ->
          try do
            send_and_log(traces, state)
          after
            Agent.update(state.agent_pid, &Map.put(&1, :unsynced_traces, &1.unsynced_traces - 1))
          end
        end)
      else
        # We get benefits from running in a separate process (like better GC)
        # So we async/await here to mimic the behaviour above but still apply backpressure
        task = Task.async(fn -> send_and_log(traces, state) end)
        Task.await(task)
      end
    else
      send_and_log(traces, state)
    end

    %State{state | waiting_traces: []}
  end

  defp below_sync_threshold?(state) do
    Agent.get_and_update(state.agent_pid, fn agent_state ->
      if agent_state.unsynced_traces < state.sync_threshold do
        {true, Map.put(agent_state, :unsynced_traces, agent_state.unsynced_traces + 1)}
      else
        {false, agent_state}
      end
    end)
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

  @spec add_analytics_sample_rate(map, Span.t()) :: map
  defp add_analytics_sample_rate(metrics, %{tags: nil}), do: metrics

  defp add_analytics_sample_rate(metrics, %{tags: tags}) do
    case Keyword.get(tags, :analytics_event) do
      nil -> metrics
      _event -> Map.merge(metrics, %{"_dd1.sr.eausr" => 1})
    end
  end

  defp sampling_rate_used_params(sampling) do
    cond do
      sampling[:sampling_mechanism_used] == SpandexDatadog.DatadogConstants.sampling_mechanism_used()[:RULE] ->
        %{"_dd.rule_psr" => sampling[:sampling_rate_used]}

      sampling[:sampling_mechanism_used] == SpandexDatadog.DatadogConstants.sampling_mechanism_used()[:AGENT] ->
        %{"_dd.agent_psr" => sampling[:sampling_rate_used]}

      true ->
        %{}
    end
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

  @spec encode(data :: term) :: iodata | no_return
  defp encode(data),
    do: data |> deep_remove_nils() |> Msgpax.pack!(data)

  @spec push(body :: iodata(), headers, State.t()) :: any()
  defp push(body, headers, %State{http: http, host: host, port: port}),
    do: http.put("#{host}:#{port}/v0.4/traces", body, headers)

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

  defp term_to_string(term) when is_boolean(term), do: inspect(term)
  defp term_to_string(term) when is_binary(term), do: term
  defp term_to_string(term) when is_atom(term), do: term
  defp term_to_string(term), do: inspect(term)
end
