defmodule SpandexDatadog.MixProject do
  use Mix.Project

  def project do
    [
      app: :spandex_datadog,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:spandex, "~> 2.0"},
      {:httpoison, "~> 0.13", only: :test},
      {:msgpax, "~> 1.1"}
    ]
  end
end
