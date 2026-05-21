defmodule Realtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :realtime,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets],
      mod: {Realtime.Application, []}
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 2.10"},
      {:jason, "~> 1.4"}
    ]
  end
end
