defmodule SpandexDatadog.AgentHttpClient do
  @callback send_traces(%{host: String.t(), port: integer(), body: iodata(), headers: list()}) ::
              {:ok, %{status: integer(), body: map()}} | {:error, any()}

  def send_traces(%{host: host, port: port, body: body, headers: headers}),
    do: impl().send_traces(%{host: host, port: port, body: body, headers: headers})

  defp impl do
    Application.get_env(:spandex_datadog, :agent_http_client, SpandexDatadog.AgentHttpClient.Impl)
  end
end
