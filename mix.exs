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
      source_url: "https://github.com/azabroflovski/fetch",
      homepage_url: "https://github.com/azabroflovski/fetch",
      docs: &docs/0
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
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

  defp docs do
    [
      main: "Fetch",
      extras: ["README.md"]
    ]
  end
end
