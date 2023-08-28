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

    {:ok, agent_pid} = Agent.start_link(fn -> 0 end)

    state = %State{
      asynchronous_send?: true,
      host: opts[:host],
      port: opts[:port],
      verbose?: opts[:verbose?],
      http: opts[:http],
      waiting_traces: [],
      batch_size: opts[:batch_size],
      sync_threshold: opts[:sync_threshold],
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

    if verbose? do
      Logger.debug(fn -> "Trace response: #{inspect(response)}" end)
    end

    :ok
  end

  @deprecated "Please use format/3 instead"
  @doc false
  @spec format(Trace.t()) :: map()
  def format(%Trace{spans: spans, priority: priority, baggage: baggage}) do
    Enum.map(spans, fn span -> format(span, priority, baggage) end)
  end

  @deprecated "Please use format/3 instead"
  @doc false
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
          _sampling_priority_v1: priority,
          "_dd.rule_psr": 1.0,
          "_dd.limit_psr": 1.0
        })
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
            Agent.update(state.agent_pid, fn count -> count - 1 end)
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
    Agent.get_and_update(state.agent_pid, fn count ->
      if count < state.sync_threshold do
        {true, count + 1}
      else
        {false, count}
      end
    end)
  end

  @spec meta(Span.t()) :: map
  defp meta(span) do
    %{}
    |> add_env_data(span)
    |> add_version_data(span)
    |> add_error_data(span)
    |> add_http_data(span)
    |> add_sql_data(span)
    |> add_tags(span)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  @spec add_env_data(map, Span.t()) :: map
  defp add_env_data(meta, %Span{env: nil}), do: meta

  defp add_env_data(meta, %Span{env: env}) do
    Map.put(meta, :env, env)
  end

  @spec add_version_data(map, Span.t()) :: map
  defp add_version_data(meta, %Span{service_version: nil}), do: meta

  defp add_version_data(meta, %Span{service_version: version}) do
    Map.put(meta, :version, version)
  end

  @spec add_error_data(map, Span.t()) :: map
  defp add_error_data(meta, %{error: nil}), do: meta

  defp add_error_data(meta, %{error: error}) do
    meta
    |> add_error_kind(error[:exception])
    |> add_error_message(error[:exception])
    |> add_error_stacktrace(error[:stacktrace])
  end

  @spec add_error_kind(map, Exception.t() | nil) :: map
  defp add_error_kind(meta, %struct{}) do
    meta
    # set 'error.type' for backward compatibility reasons
    # the value that datadog expects is 'error.kind'
    |> Map.put("error.type", struct)
    |> Map.put("error.kind", struct)
  end

  defp add_error_kind(meta, _), do: meta

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
    do: http.put("#{host}:#{port}/v0.3/traces", body, headers)

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
