defmodule SpandexDatadog.Adapter do
  @moduledoc """
  A Datadog APM implementation for Spandex.
  """

  @behaviour Spandex.Adapter

  require Logger

  alias Spandex.{
    SpanContext,
    Tracer
  }

  @max_id 9_223_372_036_854_775_807

  @propagation_style_extract ["Datadog", "B3", "B3 single header"]
  @propagation_style_inject ["Datadog", "B3"]

  defmodule SpandexDatadog.Extractor do
    @extract_resources %{
      "B3" => SpandexDatadog.B3.Extractor,
      "B3 single header" => SpandexDatadog.B3Single.Extractor,
      "Datadog" => SpandexDatadog.Datadog.Extractor,
    }

    @spec extract(Plug.Conn.t(), binary) :: binary() | nil
    def extract(conn = %Plug.Conn{}, key) do
      conn
      |> Plug.Conn.get_req_header(key)
      |> List.first()
    end
    @spec extract(%{}, binary) :: binary() | nil
    def extract(headers, key) when is_map(headers), do: Map.get(headers, key, nil)
    @spec extract([], binary) :: binary() | nil
    def extract(headers, key) when is_list(headers), do: Enum.find_value(headers, fn {k, v} -> if k == key, do: v end)

    @spec parse_value(binary(), integer()) :: integer() | nil
    def parse_value(value, base \\ 10)
    def parse_value(value, base) when is_binary(value) do
      case Integer.parse(value, base) do
        {int, _} -> int
        _ -> nil
      end
    end
    def parse_value(_value, _base), do: nil

    @spec create_span_context(integer(), integer(), integer()) :: {:ok, SpanContext.t()} | nil
    def create_span_context(nil, _parent_id, _priority), do: nil
    def create_span_context(_trace_id, nil, _priority), do: nil
    def create_span_context(trace_id, parent_id, priority) do
      {:ok, %SpanContext{
        trace_id: trace_id,
        parent_id: parent_id,
        priority: priority || 1
      }}
    end

    @spec extract_context(Plug.Conn.t() | %{} | [], [binary()]) :: {:ok, SpanContext.t()} | {:error, :no_distributed_trace}
    def extract_span_context(conn_or_headers, propagation_style_extract) do
      propagation_style_extract
      |> Enum.find_value(fn extractor ->
        case @extract_resources[extractor].extract_span_context(conn_or_headers) do
          nil -> false
          span_context -> span_context
        end
      end) || {:error, :no_distributed_trace}
    end

    @doc """
    Returns all tracing headers for the given span context.
    The propagation_style_inject allows to specify which different headers should be created.
    """
    @spec tracing_headers(SpanContext.t(), [binary()]) :: [binary()]
    def tracing_headers(span_context, propagation_style_inject) do
      propagation_style_inject
      |> Enum.flat_map(fn injector ->
        @extract_resources[injector].tracing_headers(span_context)
      end)
    end
  end

  defmodule SpandexDatadog.B3.Extractor do
    import SpandexDatadog.Extractor

    @parent_id_key "x-b3-spanid"
    @priority_key "x-b3-sampled"
    @trace_id_key "x-b3-traceid"

    def extract_span_context(conn_or_headers) do
      trace_id = conn_or_headers
        |> extract(@trace_id_key)
        |> parse_value(16)

      parent_id = conn_or_headers
        |> extract(@parent_id_key)
        |> parse_value(16)

      priority = conn_or_headers
        |> extract(@priority_key)
        |> parse_value()

      create_span_context(trace_id, parent_id, priority)
    end

    def tracing_headers(%SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}) do
      [
        {@trace_id_key, Integer.to_string(trace_id, 16)},
        {@parent_id_key, Integer.to_string(parent_id, 16)},
        {@priority_key, to_string(priority)}
      ]
    end
  end

  defmodule SpandexDatadog.Datadog.Extractor do
    import SpandexDatadog.Extractor

    @parent_id_key "x-datadog-parent-id"
    @priority_key "x-datadog-sampling-priority"
    @trace_id_key "x-datadog-trace-id"

    def extract_span_context(conn_or_headers) do
      trace_id = conn_or_headers
        |> extract("x-datadog-trace-id")
        |> parse_value()

      parent_id = conn_or_headers
        |> extract("x-datadog-parent-id")
        |> parse_value()

      priority = conn_or_headers
        |> extract("x-datadog-sampling-priority")
        |> parse_value()

      create_span_context(trace_id, parent_id, priority)
    end

    def tracing_headers(%SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}) do
      [
        {@trace_id_key, to_string(trace_id)},
        {@parent_id_key, to_string(parent_id)},
        {@priority_key, to_string(priority)}
      ]
    end
  end

  defmodule SpandexDatadog.B3Single.Extractor do
    import SpandexDatadog.Extractor

    @b3_single_key "x-b3"

    def extract_span_context(conn_or_headers) do
      {trace_id, parent_id, priority} =
        conn_or_headers
          |> extract(@b3_single_key)
          |> split_header_and_parse()

      create_span_context(trace_id, parent_id, priority)
    end

    def tracing_headers(%SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}) do
      [
        {@b3_single_key, "#{Integer.to_string(trace_id, 16)}-#{Integer.to_string(parent_id, 16)}-#{to_string(priority)}"}
      ]
    end

    defp split_header_and_parse(nil), do: {nil, nil, nil}
    defp split_header_and_parse(value) do
      case String.split(value, "-") do
        [trace_id, parent_id, priority] -> {parse_value(trace_id, 16), parse_value(parent_id, 16), parse_value(priority)}
        [trace_id, parent_id] -> {parse_value(trace_id, 16), parse_value(parent_id, 16), nil}
        _ -> {nil, nil, nil}
      end
    end
  end

  @impl Spandex.Adapter
  def trace_id(), do: :rand.uniform(@max_id)

  @impl Spandex.Adapter
  def span_id(), do: trace_id()

  @impl Spandex.Adapter
  def now(), do: :os.system_time(:nano_seconds)

  @impl Spandex.Adapter
  @spec default_sender() :: SpandexDatadog.ApiServer
  def default_sender() do
    SpandexDatadog.ApiServer
  end

  @doc """
  Fetches the Datadog-specific conn request headers if they are present.
  """
  @impl Spandex.Adapter
  @spec distributed_context(conn :: Plug.Conn.t(), Tracer.opts()) ::
          {:ok, SpanContext.t()}
          | {:error, :no_distributed_trace}
  def distributed_context(%Plug.Conn{} = conn, _opts) do
    Logger.info("distributed_context _opts: #{inspect(_opts)}")

    conn
    |> SpandexDatadog.Extractor.extract_span_context(@propagation_style_extract)
  end

  @impl Spandex.Adapter
  @spec distributed_context(headers :: Spandex.headers(), Tracer.opts()) ::
          {:ok, SpanContext.t()}
          | {:error, :no_distributed_trace}
  def distributed_context(headers, _opts) do
    headers
    |> SpandexDatadog.Extractor.extract_span_context(headers, @propagation_style_extract)
  end

  @doc """
  Injects Datadog-specific HTTP headers to represent the specified SpanContext
  """
  @impl Spandex.Adapter
  @spec inject_context([{term(), term()}], SpanContext.t(), Tracer.opts()) :: [{term(), term()}]
  def inject_context(headers, %SpanContext{} = span_context, _opts) when is_list(headers) do
    span_context
    |> SpandexDatadog.Extractor.tracing_headers(@propagation_style_inject)
    |> Kernel.++(headers)
  end

  def inject_context(headers, %SpanContext{} = span_context, _opts) when is_map(headers) do
    span_context
    |> SpandexDatadog.Extractor.tracing_headers(@propagation_style_inject)
    |> Enum.into(%{})
    |> Map.merge(headers)
  end
end
