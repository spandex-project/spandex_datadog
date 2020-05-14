defmodule SpandexDatadog.MixProject do
  use Mix.Project

  @version "0.6.0"

  def project do
    [
      app: :spandex_datadog,
      description: description(),
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        "coveralls.circle": :test,
        coveralls: :test
      ]
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
      maintainers: ["Zachary Daniel", "Greg Mefford"],
      licenses: ["MIT License"],
      links: %{"GitHub" => "https://github.com/spandex-project/spandex_datadog"}
    ]
  end

  defp description do
    """
    A datadog API adapter for spandex.
    """
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md"
      ]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:excoveralls, "~> 0.10", only: :test},
      {:git_ops, "~> 0.3.4", only: [:dev]},
      {:inch_ex, github: "rrrene/inch_ex", only: [:dev, :test]},
      {:spandex, "~> 3.0"},
      {:httpoison, "~> 0.13", only: :test},
      {:msgpax, "~> 2.2.1"}
    ]
  end
end
