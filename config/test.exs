use Mix.Config

config :logger, :console,
  level: :debug,
  colors: [enabled: false],
  format: "$time $metadata[$level] $message\n",
  metadata: [:trace_id, :span_id]

config :spandex_datadog, SpandexDatadog.Test.Support.Tracer,
  service: :spandex_test,
  adapter: SpandexDatadog.Adapter,
  sender: SpandexDatadog.Test.Support.TestApiServer,
  env: "test",
  resource: "default",
  service_version: "v1",
  services: [
    spandex_test: :db
  ]
