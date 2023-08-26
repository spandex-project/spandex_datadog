defmodule SpandexDatadog.MixProject do
  use Mix.Project

  @source_url "https://github.com/spandex-project/spandex_datadog"
  @version "1.4.0"

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
      {:spandex, "~> 3.2"},
      {:telemetry, "~> 0.4.2 or ~> 1.0"},
      # Dev- and test-only deps
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:httpoison, "~> 0.13 or ~> 1.0 or ~> 2.0", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
