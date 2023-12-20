defmodule SpandexDatadog.MixProject do
  use Mix.Project

  @source_url "https://github.com/spandex-project/spandex_datadog"
  @version "1.5.0"

  def project do
    [
      app: :spandex_datadog,
      deps: deps(),
      description: "A datadog API adapter for spandex.",
      docs: docs(),
      elixir: "~> 1.6",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      name: :spandex_datadog,
      maintainers: ["Greg Mefford"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "https://hexdocs.pm/spandex_datadog/changelog.html",
        "GitHub" => @source_url,
        "Sponsor" => "https://github.com/sponsors/GregMefford"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      extras: ["CHANGELOG.md", "README.md"],
      main: "readme",
      formatters: ["html"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      {:msgpax, "~> 2.2.1 or ~> 2.3"},
      {:jason, "~> 1.2"},
      {:spandex, github: "surgeventures/spandex", commit: "1af5f8aa98c9b2ca576d435b3b6ff80baa3ca25a"},
      {:telemetry, "~> 0.4.2 or ~> 1.0"},
      # Dev- and test-only deps
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:httpoison, "~> 0.13 or ~> 1.0 or ~> 2.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 0.5", only: :test}
    ]
  end
end
