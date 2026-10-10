defmodule Barkpark.Auth.PublicRead do
  @moduledoc """
  Helpers for the weekly `public-read` API token rotation.

  Raw tokens are 32 random bytes, URL-safe base64 encoded with no padding.
  Only the SHA256 hash is persisted (via `Barkpark.Auth.create_token/5`);
  the plaintext is returned once from `create_public_read_token/2` so the
  caller can hand it to the deploy pipeline.
  """

  import Ecto.Query
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  require Logger

  @label_prefix "public-read-"
  @token_file_default "/opt/barkpark/.env.public_token"
  # 8 days: the weekly cadence plus a 24 h grace for the previous deploy.
  @grace_seconds 8 * 24 * 60 * 60

  @doc """
  Create a new public-read token row.

  Returns `{:ok, raw_token, row}` on success. `raw_token` is the only
  place the plaintext will ever be exposed.
  """
  def create_public_read_token(label, dataset \\ "production") when is_binary(label) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    # THE INSTANCE DEFAULT IS NAMED HERE, NOT FALLEN INTO (task-e0e6454b8b2045ae).
    # `Auth.create_token/5` used to resolve `nil -> default_workspace_id()`
    # itself, which handed EVERY forgetful caller a membership in whatever
    # workspace holds the default seat. That fallback is gone. This module is
    # the one caller that genuinely means the instance default — `public-read`
    # is a SINGLETON INSTANCE credential (see `delete_public_read_tokens/1`
    # below, an instance-wide sweep with no workspace predicate) — so it
    # resolves the seat explicitly and passes it. A VACANT seat stays vacant:
    # `get_default_workspace/0` degrades to `nil` by design, and `nil` here
    # mints the token workspace-less exactly as before.
    ws_id =
      case Tenancy.get_default_workspace() do
        nil -> nil
        ws -> ws.id
      end

    case Auth.create_token(raw, label, dataset, ["public-read"], ws_id) do
      {:ok, row} -> {:ok, raw, row}
      error -> error
    end
  end

  @doc """
  Is the weekly rotation switched on? Ships OFF: `config :barkpark,
  :public_read_rotation, enabled: false` (runtime switch
  `BARKPARK_PUBLIC_READ_ROTATION=on`). Turning it on mints a new token every
  week and purges the previous one after 8 days, so every consumer of the
  old value must be reached by the token file or the deploy hook first.
  """
  @spec rotation_enabled?() :: boolean()
  def rotation_enabled? do
    Application.get_env(:barkpark, :public_read_rotation, []) |> Keyword.get(:enabled, false) ==
      true
  end

  @doc """
  One weekly rotation: mint `public-read-<ISO date>`, write the plaintext to
  the token file (0600) the deploy reads, POST it to `VERCEL_DEPLOY_HOOK` when
  set, and purge `public-read` rows older than 8 days.

  The core job `Barkpark.Auth.PublicReadRotationWorker` and the manual
  `mix barkpark.rotate_public_read` both call this. Options (tests):
  `:today`, `:now`, `:token_file`, `:deploy_hook` (`false` skips it).

  Returns `{:ok, %{label: label, purged: n}}` — never the plaintext, so a job
  result or a log line cannot carry it — or `{:error, reason}`.
  """
  @spec rotate(keyword()) ::
          {:ok, %{label: String.t(), purged: non_neg_integer()}} | {:error, term()}
  def rotate(opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    label = @label_prefix <> Date.to_iso8601(today)
    cutoff = DateTime.add(now, -@grace_seconds, :second)

    with {:ok, raw, _row} <- create_public_read_token(label),
         :ok <- write_token_file(Keyword.get(opts, :token_file, token_file_path()), raw),
         :ok <-
           notify_deploy_hook(
             Keyword.get(opts, :deploy_hook, System.get_env("VERCEL_DEPLOY_HOOK")),
             raw
           ),
         {:ok, purged} <- purge_public_read_older_than(cutoff) do
      {:ok, %{label: label, purged: purged}}
    end
  end

  defp token_file_path, do: System.get_env("PUBLIC_READ_TOKEN_FILE") || @token_file_default

  # The path is OPERATOR configuration, never request data: the
  # PUBLIC_READ_TOKEN_FILE env var or the fixed /opt/barkpark default, and in
  # tests a `:token_file` opt. No request path reaches `rotate/1` (its callers
  # are the cron worker and a mix task), so there is no traversal to steer.
  # The same File.write/chmod ran unflagged in the mix task this was lifted from.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_token_file(path, raw) do
    case File.write(path, raw <> "\n") do
      :ok ->
        _ = File.chmod(path, 0o600)
        :ok

      {:error, reason} ->
        {:error, {:token_file, path, reason}}
    end
  end

  # A deploy hook failure is logged, never fatal: the token file already holds
  # the new value, and the old token stays valid for the 8-day grace.
  defp notify_deploy_hook(hook, raw) when is_binary(hook) and hook != "" do
    case Req.post(hook, json: %{"public_read_token" => raw}, retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("public-read rotation: deploy hook answered #{status}")
        :ok

      {:error, reason} ->
        Logger.warning("public-read rotation: deploy hook failed: #{inspect(reason)}")
        :ok
    end
  end

  defp notify_deploy_hook(_hook, _raw) do
    Logger.info("public-read rotation: VERCEL_DEPLOY_HOOK not set; skipping deploy notify")
    :ok
  end

  @doc """
  Delete public-read token rows older than `cutoff` (a `DateTime`).
  Returns `{:ok, count_deleted}`.

  OPERATOR-ONLY, INSTANCE-WIDE. This is a `delete_all` with no workspace
  predicate — by design: the `public-read` tier is a singleton instance-level
  credential, not a per-tenant one, and `create_public_read_token/2` binds its
  row to the seeded Default workspace it resolves and names EXPLICITLY (there
  is no longer any fallback inside `Auth.create_token/5` to lean on), so
  scoping the sweep to a tenant would simply break it. The only caller is
  `rotate/1` — run weekly by the core job `Barkpark.Auth.PublicReadRotationWorker`
  (when switched on) or by hand via `mix barkpark.rotate_public_read`; nothing
  on the request path reaches this function, so it is not an HTTP-reachable
  mass-delete.

  What it IS reachable for is COLLATERAL: the row filter is a caller-chosen
  `label`, and callers choose labels through request paths. Two fences narrow
  it to rows this module actually mints:

    * the KIND fence (`kind == "api"`) — ticket keys mirror their
      operator-chosen name into `label`, so a key named "public-read-…" would
      otherwise be swept, silently destroying an outsider's identity.
    * the TIER fence (`"public-read" in permissions`) — `TokenController` lets
      a tenant label its own api-kind token freely, in ANY workspace. Before
      this predicate, a token labelled "public-read-my-blog-feed" was deleted
      by the weekly timer on a label-prefix match alone. The predicate is the
      same tier test `BarkparkWeb.Plugs.PublicRead.public_read_token?/1` uses,
      and `create_public_read_token/2` always stamps `["public-read"]`, so no
      real rotation token escapes.
  """
  def purge_public_read_older_than(%DateTime{} = cutoff) do
    pattern = @label_prefix <> "%"

    {n, _} =
      ApiToken
      |> where([t], like(t.label, ^pattern))
      |> where([t], t.kind == "api")
      |> where([t], ^"public-read" in t.permissions)
      |> where([t], t.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, n}
  end
end
