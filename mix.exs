defmodule PoolLad.MixProject do
  use Mix.Project

  def project do
    [
      app: :pool_lad,
      version: "0.0.1",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      description: description(),
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      filter_prefix: "PoolLad",
      main: "overview",
      assets: "assets",
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      nest_modules_by_prefix: [PoolLad]
    ]
  end

  defp extras do
    [
      # License
      "LICENSE.md",

      # Introduction
      "guides/introduction/overview.md"
    ]
  end

  defp groups_for_extras do
    [
      Introduction: ~r/guides\/introduction\//
    ]
  end

  defp package do
    [
      # These are the default files included in the package
      files: ~w(lib mix.exs README.md),
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/hqoss/pool_lad"},
      maintainers: ["Slavo Vojacek"]
    ]
  end

  defp description do
    "🙅‍♂️ A simpler and more modern Poolboy."
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dev/Test-only deps
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.11", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: [:dev, :test], runtime: false}
    ]
  end
end
