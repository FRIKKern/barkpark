defmodule Barkpark.Content.Papers.IdempotencyPort do
  @moduledoc """
  The dedup interface the paper block-op write path needs, declared BY content.

  `apply_paper_block_ops_once/6` runs one request-identified batch exactly once:
  it claims a request key inside its transaction, applies the ops, and completes
  the claim. That is all content needs from a dedup store — and content is a
  KERNEL concept, so it must not reach out to the `idempotency` feature to get
  it. Content declares the interface here; the feature implements it
  (`Barkpark.Idempotency` carries `@behaviour` for this module — feature→kernel,
  the allowed direction); the binding is injected through application env.

  The binding is resolved at RUNTIME on purpose. A module literal written in
  this tree — even as a `Application.get_env/3` default — is an alias reference
  the compiler records as a dependency, which is exactly the `content>idempotency`
  edge the Boundary gate (`tooling/concept-map/ci-boundary.mjs`) rejects. So the
  default lives in `config/config.exs` and an unbound port raises loudly at
  first use rather than silently falling back.
  """

  @typedoc "SHA-256 hex digest identifying one request."
  @type key_hash :: String.t()

  @typedoc "The payload fingerprint a key is claimed for; reuse under a different scope fails closed."
  @type scope :: String.t()

  @doc """
  Reserve `key_hash` for `scope` inside the caller's open transaction.

  `:claimed` — the caller owns execution. `{:replay, receipt}` — a completed
  claim for the same scope exists. `:in_progress` — a concurrent request holds
  the reservation. `{:error, reason}` — the claim is refused (no transaction,
  payload mismatch, undecodable receipt).
  """
  @callback claim_exact(key_hash, scope) ::
              :claimed | {:replay, map()} | :in_progress | {:error, term()}

  @doc """
  Complete the pending claim on `key_hash`/`scope` with `receipt` as its cached
  response. `{:error, reason}` when no pending claim for that exact scope exists.
  """
  @callback complete_exact(key_hash, scope, map()) :: :ok | {:error, term()}

  @doc """
  The bound implementation.

  Configured under `config :barkpark, #{inspect(__MODULE__)}, <module>`. An
  unbound port raises: a default here would reintroduce the compile-time
  reference this port exists to remove.
  """
  @spec impl() :: module()
  def impl do
    case Application.get_env(:barkpark, __MODULE__) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      other ->
        raise ArgumentError,
              "no #{inspect(__MODULE__)} implementation bound: expected " <>
                "`config :barkpark, #{inspect(__MODULE__)}, <module>`, got #{inspect(other)}"
    end
  end
end
