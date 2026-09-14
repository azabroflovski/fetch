defmodule Fetch.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/azabroflovski/fetch"

  def project do
    [
      app: :fetch,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A small just-for-fun HTTP/1.1 client written in plain Elixir/OTP.",
      package: package(),
      name: "Fetch",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:ssl, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Dev-only, never a runtime dependency. See AGENTS.md, section 8.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "fetch",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Fetch",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
