defmodule SpandexDatadog.AgentHttpClient.Impl do
  def send_traces(%{host: host, port: port, body: body, headers: headers}) do
    Req.put("http://#{host}:#{port}/v0.4/traces",
      body: body,
      headers: headers,
      retry: :transient,
      retry_delay: &retry_delay/1
    )
  end

  defp retry_delay(attempt) do
    # 3 retries with 10% jitter, example delays: 484ms, 945ms, 1908ms
    trunc(Integer.pow(2, attempt) * 500 * (1 - 0.1 * :rand.uniform()))
  end
end
