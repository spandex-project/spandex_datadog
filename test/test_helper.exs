ExUnit.start()

Mox.defmock(SpandexDatadog.MockAgentHttpClient, for: SpandexDatadog.AgentHttpClient)
Application.put_env(:spandex_datadog, :agent_http_client, SpandexDatadog.MockAgentHttpClient)
