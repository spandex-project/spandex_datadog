defmodule SpandexDatadog.ApiServer do
  @moduledoc """
  Implements worker for sending spans to datadog as GenServer in order to send traces async.
  """
  use Supervisor

  alias __MODULE__.Buffer
  alias __MODULE__.Client
  alias __MODULE__.Reporter

  alias Spandex.{
    Span,
    Trace
  }

  require Logger

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

    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    buffer = Buffer.new()
    reporter_opts =
      opts
      |> Map.new()
      |> Map.take([:http, :verbose?, :host, :port])
      |> Map.put(:buffer, buffer)

    children = [
      {Reporter, reporter_opts},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Send spans asynchronously to DataDog.
  """
  @spec send_trace(Trace.t(), Keyword.t()) :: :ok
  def send_trace(%Trace{} = trace, _opts \\ []) do
    :telemetry.span([:spandex_datadog, :send_trace], %{trace: trace}, fn ->
      result = Buffer.add_trace(trace)
      {result, %{trace: trace}}
    end)
  end

  @deprecated "Please use send_trace/2 instead"
  @doc false
  @spec send_spans([Span.t()], Keyword.t()) :: :ok
  def send_spans(spans, opts \\ []) when is_list(spans) do
    trace = %Trace{spans: spans}
    send_trace(trace, opts)
  end

  # Leaving these here for api versioning purposes. But this logic has
  # been moved to the client module.
  @doc false
  @deprecated "Please use format/3 instead"
  @spec format(Trace.t() | Span.t()) :: map()
  def format(trace), do: Client.format(trace)

  @doc false
  def format(span, priority, baggage), do: Client.format(span, priority, baggage)
end
