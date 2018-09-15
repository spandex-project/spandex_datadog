defmodule SpandexDatadog.MixProject do
  use Mix.Project

  def project do
    [
      app: :spandex_datadog,
      description: description(),
      version: "0.2.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:spandex, "~> 2.3"},
      {:httpoison, "~> 0.13", only: :test},
      {:msgpax, "~> 1.1"}
    ]
  end
end
