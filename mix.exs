defmodule SpandexDatadog.MixProject do
  use Mix.Project

  @source_url "https://github.com/spandex-project/spandex_datadog"
  @version "1.1.0"

  def project do
    [
      app: :spandex_datadog,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      deps: deps(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      description: "A datadog API adapter for spandex.",
      name: :spandex_datadog,
      maintainers: ["Zachary Daniel", "Greg Mefford"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "https://hexdocs.pm/spandex_datadog/changelog.html",
        "GitHub" => @source_url
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
      {:msgpax, "~> 2.2.1"},
      {:spandex, "~> 3.0"},
      {:telemetry, "~> 0.4"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:git_ops, "~> 2.0", only: [:dev]},
      {:httpoison, "~> 0.13 or ~> 1.0", only: :test},
      {:inch_ex, "~> 2.0", only: [:dev, :test]}
    ]
  end
end
