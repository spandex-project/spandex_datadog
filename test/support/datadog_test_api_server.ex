defmodule Spandex.Test.DatadogTestApiServer do
  @moduledoc """
  Simply sends the data that would have been sent to datadog to self() as a message
  so that the test can assert on payloads that would have been sent to datadog
  """
  def send_trace(trace, _opts \\ []) do
    formatted = SpandexDatadog.ApiServer.format(trace)
    send(self(), {:sent_datadog_spans, formatted})
  end
end
