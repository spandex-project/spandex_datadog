defmodule SpandexDatadog.Adapter do
  @moduledoc """
  A datadog APM implementation for spandex.
  """

  @behaviour Spandex.Adapter

  require Logger
  alias Spandex.SpanContext

  @max_id 9_223_372_036_854_775_807

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
  Fetches the datadog trace & parent IDs from the conn request headers
  if they are present.
  """
  @impl Spandex.Adapter
  @spec distributed_context(conn :: Plug.Conn.t(), Keyword.t()) ::
          {:ok, SpanContext.t()}
          | {:error, :no_distributed_trace}
  def distributed_context(%Plug.Conn{} = conn, _opts) do
    trace_id = get_first_header(conn, "x-datadog-trace-id")
    parent_id = get_first_header(conn, "x-datadog-parent-id")
    priority = get_first_header(conn, "x-datadog-sampling-priority") || 1

    if is_nil(trace_id) || is_nil(parent_id) do
      {:error, :no_distributed_trace}
    else
      {:ok, %SpanContext{trace_id: trace_id, parent_id: parent_id, priority: priority}}
    end
  end

  @spec get_first_header(Plug.Conn.t(), String.t()) :: integer() | nil
  defp get_first_header(conn, header_name) do
    conn
    |> Plug.Conn.get_req_header(header_name)
    |> List.first()
    |> parse_header()
  end

  defp parse_header(header) when is_bitstring(header) do
    case Integer.parse(header) do
      {int, _} -> int
      _ -> nil
    end
  end

  defp parse_header(_header), do: nil
end
