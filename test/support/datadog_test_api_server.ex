defmodule SpandexDatadog.Test.Support.TestApiServer do
  @moduledoc """
  Simply sends the data that would have been sent to datadog to self() as a message
  so that the test can assert on payloads that would have been sent to datadog
  """

  alias Spandex.Trace
  alias SpandexDatadog.ApiServer

  def send_trace(trace, _opts \\ []) do
    send(self(), {:sent_datadog_spans, format(trace)})
  end

  defp format(%Trace{spans: spans, priority: priority, baggage: baggage}) do
    Enum.map(spans, fn span -> ApiServer.format(span, priority, baggage) end)
  end
end
