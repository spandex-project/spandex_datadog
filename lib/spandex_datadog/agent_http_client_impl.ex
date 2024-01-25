defmodule SpandexDatadog.AgentHttpClient.Impl do
  def send_traces(%{host: host, port: port, body: body, headers: headers}) do
    Req.put("http://#{host}:#{port}/v0.4/traces", body: body, headers: headers, retry: :transient)
  end
end
