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
      :agent_pid
    ]
  end

  # Same as HTTPoison.headers
  @type headers :: [{atom, binary}] | [{binary, binary}] | %{binary => binary} | any

  @headers [{"Content-Type", "application/msgpack"}]

  @start_link_opts Optimal.schema(
                     opts: [
                       host: :string,
                       port: [:integer, :string],
                       verbose?: :boolean,
                       http: :atom,
                       batch_size: :integer,
                       sync_threshold: :integer,
                       api_adapter: :atom
                     ],
                     defaults: [
                       host: "localhost",
                       port: 8126,
                       verbose?: false,
                       batch_size: 10,
                       sync_threshold: 20,
                       api_adapter: SpandexDatadog.ApiServer
                     ],
                     required: [:http],
                     describe: [
                       verbose?: "Only to be used for debugging: All finished traces will be logged",
                       host: "The host the agent can be reached at",
                       port: "The port to use when sending traces to the agent",
                       batch_size: "The number of traces that should be sent in a single batch",
                       sync_threshold:
                         "The maximum number of processes that may be sending traces at any one time. This adds backpressure",
                       http:
                         "The HTTP module to use for sending spans to the agent. Currently only HTTPoison has been tested",
                       api_adapter: "Which api adapter to use. Currently only used for testing"
                     ]
                   )

  @doc """
  Starts genserver with given options.

  #{Optimal.Doc.document(@start_link_opts)}
  """
  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Optimal.validate!(opts, @start_link_opts)

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Builds server state.
  """
  @spec init(opts :: Keyword.t()) :: {:ok, State.t()}
  def init(opts) do
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
      agent_pid: agent_pid
    }

    {:ok, state}
  end

  @doc """
  Send spans asynchronously to DataDog.
  """
  @spec send_trace(Trace.t(), Keyword.t()) :: :ok
  def send_trace(%Trace{} = trace, opts \\ []) do
    :telemetry.span([:spandex_datadog, :send_trace], %{trace: trace}, fn ->
      timeout = Keyword.get(opts, :timeout, 30_000)
      result = GenServer.call(__MODULE__, {:send_trace, trace}, timeout)
      {result, %{trace: trace}}
    end)
  end

  @deprecated "Please use send_trace/2 instead"
  @doc false
  @spec send_spans([Span.t()], Keyword.t()) :: :ok
  def send_spans(spans, opts \\ []) when is_list(spans) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    trace = %Trace{spans: spans}
    GenServer.call(__MODULE__, {:send_trace, trace}, timeout)
  end

  @doc false
  def handle_call({:send_trace, trace}, _from, state) do
    state =
      state
      |> enqueue_trace(trace)
      |> maybe_flush_traces()

    {:reply, :ok, state}
  end

  @spec send_and_log([Trace.t()], State.t()) :: :ok
  def send_and_log(traces, %{verbose?: verbose?} = state) do
    headers = @headers ++ [{"X-Datadog-Trace-Count", length(traces)}]

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
        # So we async/await here to mimic the behavour above but still apply backpressure
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
  defp add_error_type(meta, %struct{}), do: Map.put(meta, "error.type", struct)
  defp add_error_type(meta, _), do: meta

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

  defp term_to_string(term) when is_binary(term), do: term
  defp term_to_string(term) when is_atom(term), do: term
  defp term_to_string(term), do: inspect(term)
end
