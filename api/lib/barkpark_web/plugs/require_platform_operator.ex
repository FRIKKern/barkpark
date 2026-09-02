defmodule BarkparkWeb.Plugs.RequirePlatformOperator do
  @moduledoc """
  The INSTANCE-OPERATOR tier: a config-backed allowlist in front of the eight
  instance-global route groups that `RequireAdmin` alone cannot narrow.

  ## The ruling this implements (quoted verbatim)

  > "A: api/ grows ONE config-backed operator allowlist plug mirroring cloud's
  > PLATFORM_ADMIN_EMAILS shape: env BARKPARK_OPERATOR_EMAILS (comma list;
  > matched against the bearer's owner email — PAT owner_user_id→email, app
  > token label \\"app:<email>\\") plus BARKPARK_OPERATOR_TOKEN_IDS (explicit
  > ids). UNSET → legacy behaviour (admin bit suffices) AND a startup warning
  > naming the seven routes; SET → allowlist only, fail closed. Same plug
  > guards all seven instance-global routes; workspace-scoped admin routes
  > untouched."

  — orchestrator, under the owner's delegated authority; owner informed
  2026-09-01, refined 2026-09-02. Filed as `task-c7e2b87f1bbca815`.

  ## Why this exists

  `Auth.has_permission?(token, "admin")` is spelled as one bit and used as two.
  `BarkparkWeb.RequireAdminRouteCensusTest` classifies 70 routes gated only by
  that bit; the `:instance_global` rows are instance-wide BY CONSTRUCTION (no
  tenant row to confine them to), which means a bearer that administers exactly
  ONE workspace could read the instance's run-secrets in cleartext, rewrite the
  one instance-wide plugin-settings record, and roll the whole release forward
  or back. This plug is the CHECK side of the fix: `admin` stays necessary,
  and on a configured instance it stops being sufficient.

  ## The eight instance-global route groups this guards

    1. `POST|GET /v1/admin/self-update`, `POST /v1/admin/rollback`,
       `POST|GET /v1/admin/site-deploy` — operator primitives (RULING row 1).
    2. `GET /v1/plugins` — the installed-plugin roster (RULING row 2).
    3. `GET|PUT|DELETE /v1/plugins/settings/:plugin_name` — the one
       instance-wide settings record, where connector credentials live
       (RULING row 3).
    4. `GET /v1/secrets`, `GET /v1/secrets/:name`,
       `GET /v1/secrets/:name/audit`, `PUT /v1/secrets/:name`,
       `DELETE /v1/secrets/:name` — the GLOBAL tier of the two-tier secret
       store (RULING row 4).
    5. `POST /v1/status/incidents`, `POST /v1/status/incidents/:id/resolve` —
       the instance status page (RULING row 5).
    6. `POST /api/playground` — the provisioning primitive (RULING row 6).
    7. `POST /api/workspaces/:workspace_slug/import` — bundle restore, whose
       target comes from the manifest (RULING row 7).
    8. `GET /v1/instance/site-deploy`, `GET /v1/instance/metrics` — the
       instance's deploy-door census and its Prometheus exposition; no tenant
       selector, but other tenants' site slugs and workspace ids ride the
       payload (RULING row 1, moved behind `require_admin` by #14793). A
       Prometheus scraper's token id goes on `BARKPARK_OPERATOR_TOKEN_IDS`.

  Workspace-scoped admin routes (`DELETE /api/workspaces/:slug`,
  `GET /api/workspaces/:slug/export`, `PUT /api/workspaces/:slug/media/blob/*`,
  the `/w/:ws/p/:proj/v1/secrets` twin on `:scoped_admin`, …) are DELIBERATELY
  untouched: they already re-bind through `Tenancy.Auth.workspace_admin?/2`, and
  putting an instance allowlist in front of them would lock every tenant admin
  out of their own workspace.

  ## Pipeline position

  Runs AFTER `RequireToken` and `RequireAdmin` (router.ex,
  `pipe_through([:api, :require_admin, :require_platform_operator])`), so the
  admin bit is still NECESSARY and this is an additional, narrower gate — never
  a replacement. An anonymous caller therefore still gets `RequireToken`'s 401,
  never this plug's 403.

  ## Resolution of the bearer's identity

  The allowlist matches on two independent keys; either one admits:

    * `BARKPARK_OPERATOR_TOKEN_IDS` — the token's own row id (`api_tokens.id`).
      The direct handle, and the one an operator uses for a machine token that
      has no human behind it.
    * `BARKPARK_OPERATOR_EMAILS` — the bearer's OWNER email, resolved in this
      order: a PAT's `owner_user_id` → `Accounts.get_user/1` → `user.email`;
      otherwise an app token's `label` of the form `"app:<email>"` (the
      convention `Auth.revoke_app_tokens_for_email/2` already matches on);
      otherwise NO email, which means no email match is possible.

  Emails are compared trimmed + downcased on both sides. Any error while
  resolving (a dangling `owner_user_id`, a DB hiccup) resolves to "no email",
  i.e. FAIL CLOSED — never to a pass.

  ## UNSET vs SET

    * BOTH env vars unset/blank → the allowlist is EMPTY and this plug is a
      PASS-THROUGH: legacy behaviour, the `admin` bit alone still suffices.
      `warn_if_unset/0` (called once from `Barkpark.Application.start/2`) logs a
      startup warning naming the eight groups and the two env vars, so a
      multi-tenant instance cannot run in this shape unknowingly.
    * EITHER env var non-empty → the allowlist is ARMED and this plug is
      ALLOWLIST-ONLY: a bearer not on it gets `403 forbidden` with
      `required: "platform_operator"` (the same vocabulary cloud's
      `BarkparkCloudWeb.Auth.require_platform_operator/2` emits), regardless of
      its `admin` bit.

  A configured instance is fail-closed by construction: with `emails` and
  `token_ids` both listed, an unrecognised bearer matches neither.
  """

  import Plug.Conn

  require Logger

  alias Barkpark.Accounts

  @emails_env "BARKPARK_OPERATOR_EMAILS"
  @ids_env "BARKPARK_OPERATOR_TOKEN_IDS"

  def init(opts), do: opts

  def call(conn, _opts) do
    %{emails: emails, token_ids: ids} = allowlist()

    cond do
      emails == [] and ids == [] -> conn
      operator?(conn.assigns[:api_token], emails, ids) -> conn
      true -> deny(conn)
    end
  end

  @doc """
  The configured operator allowlist, read from Application env at RUNTIME (so a
  release can be reconfigured without a recompile, and so a test can arm it with
  `Application.put_env/3`).

  Both lists are trimmed and blank-rejected; emails are additionally downcased.
  `%{emails: [], token_ids: []}` means UNSET — see the moduledoc.
  """
  @spec allowlist() :: %{emails: [String.t()], token_ids: [String.t()]}
  def allowlist do
    %{
      emails: normalize(Application.get_env(:barkpark, :operator_emails, [])),
      token_ids: normalize(Application.get_env(:barkpark, :operator_token_ids, []))
    }
  end

  @doc """
  Boot-time warning when the operator allowlist is UNSET.

  Called once from `Barkpark.Application.start/2`, alongside
  `Barkpark.Mailer.warn_if_undeliverable/0` — the same mechanism, not a second
  one. WARNS rather than refusing to boot: a single-tenant self-hosted instance
  is a legitimate configuration (its only admin IS the operator), so this states
  the condition instead of breaking every existing deployment.
  """
  @spec warn_if_unset() :: :ok
  def warn_if_unset do
    %{emails: emails, token_ids: ids} = allowlist()

    if emails == [] and ids == [] do
      Logger.warning("""
      [Operator] The instance-operator allowlist is UNSET (#{@emails_env} and #{@ids_env} are
      both empty), so the `admin` permission alone still opens these eight INSTANCE-GLOBAL
      route groups to ANY admin-permissioned token, including one whose only membership is an
      admin seat in a single workspace:
        1. POST|GET /v1/admin/self-update, POST /v1/admin/rollback, POST|GET /v1/admin/site-deploy
        2. GET /v1/plugins
        3. GET|PUT|DELETE /v1/plugins/settings/:plugin_name
        4. GET /v1/secrets, GET /v1/secrets/:name, GET /v1/secrets/:name/audit,
           PUT /v1/secrets/:name, DELETE /v1/secrets/:name
        5. POST /v1/status/incidents, POST /v1/status/incidents/:id/resolve
        6. POST /api/playground
        7. POST /api/workspaces/:workspace_slug/import
        8. GET /v1/instance/site-deploy, GET /v1/instance/metrics
      On a SINGLE-TENANT instance that is fine — the only admin is the operator. On a
      MULTI-TENANT one it hands your first customer-admin the instance: run-secrets in
      cleartext, the instance-wide plugin credentials record, and the release itself.
      Set #{@emails_env} (comma-separated operator emails) and/or #{@ids_env}
      (comma-separated api_token ids) to arm the allowlist; once either is non-empty the
      eight groups are allowlist-only and fail closed.
      """)
    end

    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp normalize(value) do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp operator?(nil, _emails, _ids), do: false

  defp operator?(token, emails, ids) do
    id_match?(token, ids) or email_match?(token, emails)
  end

  defp id_match?(_token, []), do: false

  defp id_match?(token, ids) do
    case Map.get(token, :id) do
      id when is_binary(id) -> String.downcase(id) in ids
      _ -> false
    end
  end

  defp email_match?(_token, []), do: false

  defp email_match?(token, emails) do
    case owner_email(token) do
      nil -> false
      email -> email in emails
    end
  end

  # PAT identity first (the token carries a real user), then the app-token label
  # convention. Anything else has no owner email — and therefore cannot be
  # admitted by the email arm at all.
  defp owner_email(token) do
    case Map.get(token, :owner_user_id) do
      user_id when is_binary(user_id) -> user_email(user_id) || label_email(token)
      _ -> label_email(token)
    end
  rescue
    # FAIL CLOSED: a resolution error is "no email", never a pass.
    error ->
      Logger.warning("[Operator] owner email resolution failed: #{inspect(error)}")
      nil
  end

  defp user_email(user_id) do
    case Accounts.get_user(user_id) do
      %{email: email} when is_binary(email) -> String.downcase(String.trim(email))
      _ -> nil
    end
  end

  defp label_email(token) do
    case Map.get(token, :label) do
      "app:" <> email when byte_size(email) > 0 -> String.downcase(String.trim(email))
      _ -> nil
    end
  end

  defp deny(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)

    body =
      env
      |> Map.delete(:status)
      # Same `code` ("forbidden") and status as RequireAdmin's 403 — the machine
      # key does not fork. `required` is the additive discriminator, spelled with
      # cloud's own vocabulary so one grep for `platform_operator` finds both
      # halves of the tier.
      |> Map.put(:required, "platform_operator")

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: body})
    |> halt()
  end
end
