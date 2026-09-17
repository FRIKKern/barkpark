defmodule Barkpark.EndpointConfig do
  @moduledoc """
  Read one key of `BarkparkWeb.Endpoint`'s config WITHOUT requiring the endpoint
  to be running.

  `BarkparkWeb.Endpoint.config/2` (and `url/0`, which is built from it) is an
  `:ets.lookup(BarkparkWeb.Endpoint, key)`, and that table is created when the
  endpoint STARTS. Two boot modes deliberately drop the endpoint from the child
  list (`Barkpark.Application.child_specs/5`):

    * `:seed` — `Barkpark.Release.seed/0`. The ETS read raised

          ** (ArgumentError) the table identifier does not refer to an existing
             ETS table ... :ets.lookup(BarkparkWeb.Endpoint, :url)

      from `print_token_banner/1`, the LAST step of a first-ever boot's seed.
      With `set -e` in `api/entrypoint.sh` that killed the container before
      `bin/barkpark start` and took the shown-once admin token with it.

    * `:one_shot` — `Barkpark.OneShot.boot!/0`, so an operator one-shot cannot
      bind the live slot's port. There the same raise was SWALLOWED by the
      resolver chain's per-plugin rescue and `mix barkpark.edges.backfill`
      reported SUCCESS having projected only the non-bulldocs edges — measured
      on the dev corpus as 962 edges with an endpoint and 94 without, exit
      status 0 both times.

  Both are invisible to `mix test`: the test node always has the endpoint up.

  ## The fallback is not a second source of truth

  `BarkparkWeb.Endpoint` defines no `init/2`, so Phoenix seeds that ETS table
  verbatim from the merged `Application.get_env(:barkpark, BarkparkWeb.Endpoint)`
  keyword list `config/runtime.exs` writes. The live table is still PREFERRED
  whenever it exists, so a serving node's answer is byte-identical to before.

  `:ets.whereis/1` rather than `Process.whereis/1`: the ETS table is exactly
  what `config/2` needs, so probing it asks the question that decides.
  """

  @endpoint BarkparkWeb.Endpoint

  @doc """
  The endpoint's configured value for `key`, or `default` when unset.

  Reads the live endpoint when its ETS table exists; otherwise reads the same
  merged application env Phoenix would have seeded that table from.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    if :ets.whereis(@endpoint) == :undefined do
      :barkpark
      |> Application.get_env(@endpoint, [])
      |> Keyword.get(key, default)
    else
      case @endpoint.config(key, default) do
        nil -> default
        value -> value
      end
    end
  end

  @doc """
  The instance's own configured public HOST (`:url` → `:host`), or `nil`.

  This is the host half of `BarkparkWeb.Endpoint.url/0` — `url/0` is assembled
  from exactly this `:url` keyword list, so on a serving node
  `URI.parse(Endpoint.url()).host` and this return the same string. Callers that
  compare hosts want only this half: see
  `Barkpark.Plugins.Bulldocs.own_public_host?/1` on why scheme and port are
  deliberately ignored.
  """
  @spec public_host() :: String.t() | nil
  def public_host do
    get(:url, []) |> Keyword.get(:host)
  end
end
