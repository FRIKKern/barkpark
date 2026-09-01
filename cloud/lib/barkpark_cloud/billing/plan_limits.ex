defmodule BarkparkCloud.Billing.PlanLimits do
  @moduledoc """
  The per-plan managed-instance ceiling AS AN OPERATOR CAN ACTUALLY SET IT — the
  committed default with the `LIMIT_*` environment override applied on top.

  ## Why this module exists (cch-prod-limit-override-seam-unmirrored)

  This resolution used to be written INLINE in `config/runtime.exs`, inside
  `if config_env() == :prod`. That put the rule somewhere no test could reach,
  and the cross-layer mirror guard
  (`test/barkpark_cloud/billing_client_mirror_test.exs`) said so in writing: it
  could only compare COMMITTED DEFAULTS, and it declared that acceptable
  **because `cloud/docker-compose.yml` passed no `LIMIT_*` at all**, so the
  committed default WAS what ran.

  That premise is gone. Commit `2c25288479` widened the compose environment
  block, and `cloud/docker-compose.yml` now passes all four `LIMIT_*` names
  through to the container. An operator who sets one in `cloud/.env` moves the
  server's real ceiling while the console's `PLAN_CATALOG` constant stays put —
  the console promises a ceiling the server refuses, and the guard stayed green.

  Moving the rule here makes the override seam CALLABLE, so the guard can
  compare **what actually runs** instead of what is committed:

    * `runtime.exs` calls `resolve/0`, which reads the real process environment.
      Prod's ceiling is this function's return value — there is no second copy.
    * The guard calls `resolve/0` too (so a `LIMIT_*` set in the environment the
      guard runs in reds for real), and `resolve/1` with a SYNTHETIC environment
      to prove the mirror reds on divergence without mutating global state.

  ## Why the env reads are written out longhand

  `scripts/env-census.py` derives the env census from `System.get_env` call
  sites whose argument is a double-quoted literal, and FAILS CLOSED on a dynamic
  site (its contract, rule 2). A `for {_plan, name, _} <- @overridable` loop
  passing that loop variable to `System.get_env/1` would be exactly such a site,
  and the census would stop deriving these four names — so compose would no
  longer be checked against them. `env/0` therefore names all four literally.

  (That sentence is deliberately written WITHOUT the parenthesised call form:
  the census scans raw source lines, so prose that merely quotes a dynamic call
  site IS a dynamic call site as far as the scanner is concerned. Measured — an
  earlier draft of this very paragraph failed the census.)

  That is a duplication (`@overridable` names them too), so it is PINNED: the
  guard asserts `Map.keys(env()) == env_names()`. The duplication cannot drift
  silently, which is the only reason it is allowed to exist.

  ## What this module deliberately does NOT do

  It does not know the console's numerals. Nothing server-side does — the
  console's constant lives in `priv/static/app.js`, and comparing the two is the
  guard's job, by running both sides. A third hand-typed copy of `1 / 3 / 10`
  here would be the very defect this module exists to close.
  """

  # plan => {env var, committed default}. The committed defaults MUST equal
  # `config/config.exs`'s `:limits` for these plans; the guard pins that, so this
  # module cannot become a silent fourth copy of the numerals.
  @overridable [
    {"free", "LIMIT_FREE", 1},
    {"trial", "LIMIT_TRIAL", 1},
    {"supporter", "LIMIT_SUPPORTER", 3},
    {"support_plus", "LIMIT_SUPPORT_PLUS", 10}
  ]

  # Ceilings with NO env seam. `forever` is the admin comp (effectively
  # unlimited) and `none` is the no-active-subscription fallback; neither is
  # operator-tunable, so neither can diverge from the console.
  @fixed %{"forever" => 1_000_000, "none" => 0}

  @doc """
  The operator-tunable tiers as `{plan, env_name, committed_default}`.

  The declared seam surface — what an operator can move from `cloud/.env`.
  """
  @spec overridable() :: [{String.t(), String.t(), non_neg_integer()}]
  def overridable, do: @overridable

  @doc """
  The `LIMIT_*` names that move a ceiling. THE SEAM CENSUS.

  The guard asserts this equals the set of `LIMIT_*` names
  `cloud/docker-compose.yml` passes through to the container. A new override
  seam added to compose that this module does not model reds there — which is
  precisely the edit that opened this hole in the first place.
  """
  @spec env_names() :: [String.t()]
  def env_names, do: Enum.map(@overridable, fn {_plan, name, _default} -> name end)

  @doc """
  The committed ceilings — the override seam ignored.

  Derived from `resolve/1` with an empty environment, so the committed numbers
  and the resolved numbers can never come from two different rules.
  """
  @spec committed_defaults() :: %{optional(String.t()) => non_neg_integer()}
  def committed_defaults, do: resolve(%{})

  @doc """
  A snapshot of the four `LIMIT_*` variables as THIS process sees them.

  Names written literally so `scripts/env-census.py` keeps deriving them (see the
  moduledoc). Pinned against `env_names/0` by the guard.
  """
  @spec env() :: %{optional(String.t()) => String.t() | nil}
  def env do
    %{
      "LIMIT_FREE" => System.get_env("LIMIT_FREE"),
      "LIMIT_TRIAL" => System.get_env("LIMIT_TRIAL"),
      "LIMIT_SUPPORTER" => System.get_env("LIMIT_SUPPORTER"),
      "LIMIT_SUPPORT_PLUS" => System.get_env("LIMIT_SUPPORT_PLUS")
    }
  end

  @doc """
  The ceilings the server will ACTUALLY enforce for `env` — the committed
  default per plan, replaced by the `LIMIT_*` value wherever one is set.

  `resolve/0` reads the live process environment; this is what `runtime.exs`
  installs as `config :barkpark_cloud, BarkparkCloud.Billing, limits: ...` in
  prod, and therefore what `Billing.limits/0` returns on a running box.
  """
  @spec resolve(%{optional(String.t()) => String.t() | nil}) ::
          %{optional(String.t()) => non_neg_integer()}
  def resolve(env \\ env()) do
    Enum.reduce(@overridable, @fixed, fn {plan, name, default}, acc ->
      Map.put(acc, plan, ceiling(Map.get(env, name), default))
    end)
  end

  @doc """
  The plans whose ceiling came FROM THE ENVIRONMENT rather than from the
  committed default, for `env`.

  The guard reports this beside every comparison, and asserts the report carries
  it — so an edit that drops the environment arm shrinks the report and reds by
  name instead of quietly going back to comparing committed defaults.
  """
  @spec overridden(%{optional(String.t()) => String.t() | nil}) :: [String.t()]
  def overridden(env \\ env()) do
    for {plan, name, _default} <- @overridable, not is_nil(Map.get(env, name)), do: plan
  end

  # The old `runtime.exs` rule, kept byte-for-byte in behaviour:
  # `String.to_integer(System.get_env("LIMIT_FREE") || "1")`. A malformed value
  # still RAISES at boot rather than falling back — an operator's typo must never
  # read as "no override was set", which would be this defect wearing a new hat.
  defp ceiling(nil, default), do: default
  defp ceiling(raw, _default) when is_binary(raw), do: String.to_integer(raw)
end
