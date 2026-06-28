defmodule BarkparkCloud.Health do
  @moduledoc """
  Liveness for the control plane itself — mirrors the spirit of api/'s own
  health probe. The control plane's only hard dependency is
  its Postgres (where it stores metadata about many Barkpark instances), so
  health is "can I round-trip a query to my own DB?".

  Returns `{:ok, %{db: :up, ...}}` when the Repo answers `SELECT 1`, and
  `{:error, %{db: :down, ...}}` otherwise — never raises to the caller.
  """

  alias BarkparkCloud.Repo

  @type result :: {:ok, map()} | {:error, map()}

  @doc """
  Probe the control plane's own liveness.

  Round-trips `SELECT 1` to the Repo. On success returns
  `{:ok, %{db: :up, checked_at: <utc_datetime>}}`.
  """
  @spec health() :: result()
  def health do
    Repo.query!("SELECT 1")
    {:ok, %{db: :up, checked_at: DateTime.utc_now()}}
  rescue
    error ->
      {:error, %{db: :down, checked_at: DateTime.utc_now(), reason: Exception.message(error)}}
  end
end
