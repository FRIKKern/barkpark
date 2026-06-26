defmodule BarkparkCloud.MixProject do
  use Mix.Project

  def project do
    [
      app: :barkpark_cloud,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BarkparkCloud.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      # cloud-8 (identity): password hashing for the User. bcrypt's 72-byte
      # input cap is mirrored by the User schema's max password length.
      {:bcrypt_elixir, "~> 3.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # `ecto.setup` mirrors api/'s: create the database then run every pending
  # migration. See the README for the full boot sequence.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
