defmodule Barkpark.Auth.TokenExpiry do
  @moduledoc """
  Mint-time expiry policy for NEW api tokens (task-a0f8cfd7f4800236, slice of
  task-eaaf13ab768f34f6). Existing rows are never read or rewritten here — this
  module only decides the `expires_at` a token is INSERTED with.

  Three rules, one per class (`:api`, `:share`, `:app`):

    * MAX AGE — `:api` 365 days, `:share` (share-edit and `public-read`) 30
      days, `:app` none (unchanged until the App shape exists). A requested
      expiry beyond the max is REFUSED with the max named, never clamped.
    * DEFAULT — read from `config :barkpark, :token_default_expiry_days`
      (`%{api: days | nil, share: days | nil}`), SHIPPED AS nil. The default only
      fills a mint that requested nothing AND whose path has no built-in horizon
      of its own (PAT 30d, share-edit 7d and claude-session 4h keep theirs).
    * NO-EXPIRY OPT-OUT — an explicit `:no_expiry` request. Admin-only (the flat
      instance `"admin"` permission, decided by the caller of `resolve/3` from
      the minting principal), and audited by `Barkpark.Auth.create_token/6`.

  ## The max vs a nil default — why today's callers do not change

  The max applies to an expiry that is REQUESTED (by the caller, or by a
  configured default). A mint that requests nothing while its class has no
  default configured is minted with no expiry, exactly as before — that is
  every deploy, fleet-support, site-deploy and `bp login` mint today. Once the
  owner configures a default for a class, a request-less mint of that class
  gets the default, so the ONLY way to a never-expiring token of that class is
  the admin opt-out. Enforcing "no expiry needs the opt-out" while the default
  is nil would 422 every one of those callers, i.e. change behaviour on a
  config that is supposed to change nothing.
  """

  @day 86_400
  @max_age_days %{api: 365, share: 30}

  @type class :: :api | :share | :app
  @type request :: nil | :no_expiry | DateTime.t()
  @type reason ::
          {:expiry_exceeds_max, class(), pos_integer()}
          | :expiry_not_in_future
          | :no_expiry_requires_admin

  @doc "The max age in days for `class`; nil = no max (`:app`)."
  @spec max_age_days(class()) :: pos_integer() | nil
  def max_age_days(:app), do: nil
  def max_age_days(class) when is_map_key(@max_age_days, class), do: @max_age_days[class]

  @doc """
  The configured default expiry in days for `class`, or nil (the shipped value).
  A configured default above the class max raises: it is operator config, and a
  default the max would refuse on every mint is a misconfiguration to surface,
  not to silently clamp.
  """
  @spec default_days(class()) :: pos_integer() | nil
  def default_days(:app), do: nil

  def default_days(class) do
    days =
      :barkpark
      |> Application.get_env(:token_default_expiry_days, %{})
      |> Map.new()
      |> Map.get(class)

    case days do
      nil ->
        nil

      d when is_integer(d) and d > 0 ->
        if d > max_age_days(class) do
          raise ArgumentError,
                "token_default_expiry_days.#{class} is #{d}, above the #{class} max age of " <>
                  "#{max_age_days(class)} days"
        end

        d

      other ->
        raise ArgumentError,
              "token_default_expiry_days.#{class} must be a positive integer or nil, got: " <>
                inspect(other)
    end
  end

  @doc """
  The policy class a permission set mints into: anything carrying
  `public-read` is `:share`, everything else `:api`. `:app` is never inferred —
  the app-token mint names it.
  """
  @spec class_for_permissions([String.t()]) :: :api | :share
  def class_for_permissions(permissions) when is_list(permissions) do
    if "public-read" in permissions, do: :share, else: :api
  end

  def class_for_permissions(_), do: :api

  @doc """
  Resolve the `expires_at` to insert.

  `opts`: `:admin?` (boolean — may this minter use `:no_expiry`), `:fallback`
  (seconds — the path's own built-in horizon, used before the configured
  default), `:now`.
  """
  @spec resolve(class(), request(), keyword()) :: {:ok, DateTime.t() | nil} | {:error, reason()}
  def resolve(class, request, opts \\ [])

  # App tokens: unchanged until the App shape exists — no max, no default.
  def resolve(:app, %DateTime{} = at, _opts), do: {:ok, DateTime.truncate(at, :second)}
  def resolve(:app, _request, _opts), do: {:ok, nil}

  def resolve(class, %DateTime{} = at, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    max = max_age_days(class)

    cond do
      DateTime.compare(at, now) != :gt -> {:error, :expiry_not_in_future}
      DateTime.diff(at, now, :second) > max * @day -> {:error, {:expiry_exceeds_max, class, max}}
      true -> {:ok, DateTime.truncate(at, :second)}
    end
  end

  def resolve(_class, :no_expiry, opts) do
    if Keyword.get(opts, :admin?, false) == true,
      do: {:ok, nil},
      else: {:error, :no_expiry_requires_admin}
  end

  def resolve(class, nil, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    seconds =
      case Keyword.get(opts, :fallback) do
        s when is_integer(s) and s > 0 -> s
        _ -> with d when is_integer(d) <- default_days(class), do: d * @day
      end

    case seconds do
      nil -> {:ok, nil}
      s -> resolve(class, DateTime.add(now, s, :second), Keyword.put(opts, :now, now))
    end
  end

  @doc "A client-facing sentence for a policy refusal — names the max."
  @spec message(reason()) :: String.t()
  def message({:expiry_exceeds_max, class, days}),
    do: "requested expiry exceeds the #{class} token max age of #{days} days"

  def message(:expiry_not_in_future), do: "requested expiry must be in the future"

  def message(:no_expiry_requires_admin),
    do: "no_expiry is an admin-only opt-out (requires the admin permission)"

  @doc "Envelope `details` for a policy refusal."
  @spec details(reason()) :: map()
  def details({:expiry_exceeds_max, class, days}),
    do: %{kind: to_string(class), max_age_days: days}

  def details(_), do: %{}
end
