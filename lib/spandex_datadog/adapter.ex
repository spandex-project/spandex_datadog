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

  # Max value for a trace_id. We only generate 63-bit integers due to
  # limitations in other languages, but other systems may use the full 64-bits.
  @max_id 9_223_372_036_854_775_807
  # @max_id Bitwise.bsl(1, 63) - 1

  @impl Spandex.Adapter
  def trace_id, do: :rand.uniform(@max_id)

  @impl Spandex.Adapter
  def span_id, do: trace_id()

  @impl Spandex.Adapter
  def now, do: :os.system_time(:nano_seconds)

  @impl Spandex.Adapter
  @spec default_sender() :: SpandexDatadog.ApiServer
  def default_sender do
    SpandexDatadog.ApiServer
  end

  @doc """
  Fetches the Datadog-specific conn request headers if they are present.
  """
  @impl Spandex.Adapter
  @spec distributed_context(Plug.Conn.t(), Tracer.opts()) ::
          {:ok, SpanContext.t()} | {:error, :no_distributed_trace}
  def distributed_context(%Plug.Conn{req_headers: headers}, opts) do
    distributed_context(headers, opts)
  end

  @impl Spandex.Adapter
  @spec distributed_context(Spandex.headers(), Tracer.opts()) ::
          {:ok, SpanContext.t()} | {:error, :no_distributed_trace}
  def distributed_context(headers, _opts) do
    headers
    |> Enum.reduce(%SpanContext{}, &extract_header/2)
    |> validate_context()
  end

  @doc """
  Injects Datadog-specific HTTP headers to represent the specified SpanContext
  """
  @impl Spandex.Adapter
  @spec inject_context(Spandex.headers(), SpanContext.t(), Tracer.opts()) :: Spandex.headers()
  def inject_context(headers, %SpanContext{} = span_context, opts) when is_map(headers) do
    inject_context(Map.to_list(headers), span_context, opts) |> Enum.into(%{})
  end

  def inject_context(headers, %SpanContext{} = span_context, _opts) when is_list(headers) do
    span_context
    |> Map.from_struct()
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Enum.reduce([], &inject_header/2)
    |> Enum.concat(headers)
  end

  # Private Helpers

  # Reduce function that sets values in SpanContext for headers
  @spec extract_header({binary(), binary()}, SpanContext.t()) :: SpanContext.t()
  defp extract_header({"x-datadog-trace-id", value}, span_context) do
    put_context_int(span_context, :trace_id, value)
  end

  defp extract_header({"x-datadog-parent-id", value}, span_context) do
    put_context_int(span_context, :parent_id, value)
  end

  defp extract_header({"x-datadog-sampling-priority", value}, span_context) do
    put_context_int(span_context, :priority, value)
  end

  defp extract_header({"x-datadog-origin", value}, span_context) do
    %{span_context | baggage: span_context.baggage ++ [{:"_dd.origin", value}]}
  end

  defp extract_header(_, span_context) do
    span_context
  end

  # Update context with value if it is an integer
  @spec put_context_int(Spandex.SpanContext.t(), atom(), binary()) :: Spandex.SpanContext.t()
  defp put_context_int(span_context, key, value) do
    case Integer.parse(value) do
      {int_value, _} ->
        Map.put(span_context, key, int_value)

      _ ->
        span_context
    end
  end

  # Determine if SpanContext is valid
  @spec validate_context(SpanContext.t()) ::
          {:ok, SpanContext.t()} | {:error, :no_distributed_trace}
  defp validate_context(%{trace_id: nil}) do
    {:error, :no_distributed_trace}
  end

  # Based on the code of the Ruby libary, it seems valid
  # to have only the trace_id and origin headers set, but not parent_id.
  # This might happen with RUM or synthetic traces.
  defp validate_context(%{parent_id: nil} = span_context) do
    if Keyword.has_key?(span_context.baggage, :"_dd.origin") do
      {:ok, span_context}
    else
      {:error, :no_distributed_trace}
    end
  end

  defp validate_context(span_context) do
    {:ok, span_context}
  end

  # Add SpanContext value to headers
  @spec inject_header({atom(), term()}, [{binary(), binary()}]) :: [{binary(), binary()}]
  defp inject_header({:baggage, []}, headers) do
    headers
  end

  defp inject_header({:baggage, baggage}, headers) do
    case Keyword.fetch(baggage, :"_dd.origin") do
      {:ok, value} ->
        [{"x-datadog-origin", value} | headers]

      :error ->
        headers
    end
  end

  defp inject_header({:trace_id, value}, headers) do
    [{"x-datadog-trace-id", to_string(value)} | headers]
  end

  defp inject_header({:parent_id, value}, headers) do
    [{"x-datadog-parent-id", to_string(value)} | headers]
  end

  defp inject_header({:priority, value}, headers) do
    [{"x-datadog-sampling-priority", to_string(value)} | headers]
  end

  defp inject_header(_, headers) do
    headers
  end
end
