defmodule MPEG.TS.MixProject do
  use Mix.Project

  def project do
    [
      app: :kim_mpeg_ts,
      version: "1.0.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/kim-company/kim_mpeg_ts",
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  defp description do
    """
    MPEG Transport Stream (TS) library. Deserializes packets and demuxes them (no
    serializer nor muxer).
    """
  end

  defp package do
    [
      organization: "kim_company",
      files: ~w(lib mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/kim-company/kim_mpeg_ts"}
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
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
