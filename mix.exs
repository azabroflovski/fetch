defmodule Fetch.MixProject do
  use Mix.Project

  def project do
    [
      app: :fetch,
      version: "0.0.1",
      elixir: "~> 1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Fetch",
      source_url: "https://github.com/azabroflovski/fetch"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp description() do
    "🚀 A lightweight HTTP library inspired by JavaScript's fetch, bringing simplicity and flexibility to Elixir HTTP requests."
  end

  defp package() do
    [
      name: "fetch",
      files: ~w(lib .formatter.exs mix.exs README*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/azabroflovski/fetch"}
    ]
  end
end
