defmodule BarkparkWeb.PatSelfMintAdminCapTest do
  @moduledoc """
  felix-w24-bl-pat-admin-mint-seam — the CONTRACT for the HTTP PAT self-mint's
  permission ceiling. Not a reproduction: every assertion here describes what
  MUST be true, and a red is a regression.

  This file began life on `origin/security/pat-mint-pin` as a REPRODUCTION of a
  live privilege escalation. It is inverted here because the escalation is
  fixed (orchestrator ruling A, delegated; owner informed 2026-09-01).

  ## What the hole was

  `BarkparkWeb.AuthController.create_token/2` (`POST /v1/auth/tokens`) resolves
  the caller's OWN membership and mints
  `Auth.max_pat_permissions_for_role(role)`. Commit 2aa3bdb6f1 (#14245)
  replaced the old `role: "member"` / `["read"]` literals with those derived
  values — so from that commit, any `owner` or `admin` of ANY workspace
  received a PAT carrying `"admin"`. `BarkparkWeb.Plugs.RequireAdmin` is an
  UNSCOPED `Auth.has_permission?(token, "admin")` — no workspace anywhere in
  the check — so that PAT cleared every `[:api, :require_admin]` route on the
  instance: `GET /v1/secrets/:name` (the INSTANCE-GLOBAL, `workspace_id IS
  NULL` run-secret store, returned in plaintext), `POST
  /v1/admin/self-update`, `/v1/admin/rollback`, secrets write/delete,
  `/v1/plugins/settings` CRUD, `POST /v1/shares`, bundle import. A workspace
  creator is written an `"owner"` membership on the workspace they just made
  (`Tenancy.do_create_owned_workspace/4`), so the escalation was self-serve.

  ## What holds now

    * STEP 1 — an owner's self-minted PAT does NOT carry `"admin"`; it is
      exactly `["read", "write"]`. `Auth`'s
      `@pat_allowed_elevated_permissions` is the ceiling and it tops out at
      `write`.
    * STEP 2 — that PAT is 403 on `GET /v1/secrets/:name`, and the secret
      value does not appear in the body.
    * CONTROL — a `member` of the same workspace still gets `["read"]` and is
      403 on the identical route (the member cap was never the bug, and this
      keeps STEP 2's 403 from being read as "the route is just closed to
      everyone with a PAT").
    * GRANDFATHER — the cap is at MINT, not at CHECK. An EXISTING
      `["read", "write", "admin"]` row (the instance operator's own
      credential; the `demo` seed's `barkpark-dev-token`) still passes
      `RequireAdmin` and still reads the secret. No migration, no revoke, no
      backfill touched `api_tokens`.

  `RequireAdmin` is deliberately UNTOUCHED: the flat instance tier is by
  design (docs/auth.md, "Hierarchy — permission ⟂ membership"). What changed is
  that a WORKSPACE role can no longer manufacture that instance-wide bit.
  Workspace-scoped administrative authority lives on the MEMBERSHIP role and is
  read by `Tenancy.Auth.workspace_admin?/2`.

  ## Caller table — every caller of `Auth.create_personal_access_token/3`

  Sweep: `grep -rn "create_personal_access_token" <repo>` (excluding
  `_build/`, `deps/`, `node_modules/`, `.git/`). Call sites only; comments and
  `@doc` mentions excluded. This CLOSES the row's "UNCLOSED EDGE" (Studio
  LiveView panes and mix tasks were never audited): there are none.

  | Call site | Threads a client-supplied permission list? | Threads the caller's REAL workspace role? |
  |---|---|---|
  | `api/lib/barkpark_web/controllers/auth_controller.ex` (`create_token/2`, `POST /v1/auth/tokens`) | NO — `params` is read for `:name` only; a body `role`/`permissions`/`owner_user_id` is ignored | **YES** — `role` comes from `TenancyAuth.membership_role/2` via `resolve_caller_workspace/1`, and `permissions` is `Auth.max_pat_permissions_for_role(role)`. **This was the live escalation; the ceiling it reads is now capped.** |
  | Studio LiveView panes (`live/studio/**`, `studio_chrome.ex`) | — | **NO CALL EXISTS.** Zero hits repo-wide. They call `Tenancy.create_workspace_with_owner/2`, never the PAT mint. |
  | `api/lib/mix/tasks/**` | — | **NO CALL EXISTS.** Zero hits across all 33 mix tasks. |
  | `api/priv/**` | — | **NO CALL EXISTS.** Zero hits. |
  | `create_personal_access_token/3` in `cloud/lib/barkpark_cloud/accounts.ex` | separate function in a separate OTP app (`BarkparkCloud.Accounts`), not this one | out of scope for this row; its own role gate is `pat_abilities_allowed?/2` in the same file |
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Secrets
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp uniq_email(prefix), do: "#{uniq(prefix)}@example.com"

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp user_bearer(user) do
    {:ok, raw} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

    raw
  end

  # Self-mint over the REAL HTTP route, as the session user — the surface the
  # ruling governs. Returns {raw_token, personal_access_token_json}.
  defp self_mint(user) do
    conn =
      scoped_conn()
      |> bearer(user_bearer(user))
      |> post("/v1/auth/tokens", %{"name" => uniq("cli")})

    assert %{"token" => raw, "personal_access_token" => pat} = json_response(conn, 201)
    {raw, pat}
  end

  # A user holding `role` in a FRESH workspace of their own — the shape of an
  # ordinary customer, with no instance-level privilege of any kind.
  defp customer_with_role(role) do
    ws = create_workspace!()
    user = register_user(uniq_email("pat-cap-#{role}"))
    {:ok, _membership} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    {ws, user}
  end

  describe "the HTTP PAT self-mint tops out at [\"read\", \"write\"] for every workspace role" do
    test "STEP 1 — an owner's self-minted PAT does NOT carry the flat \"admin\" permission" do
      {_ws, owner} = customer_with_role("owner")

      {_raw, pat} = self_mint(owner)

      assert Enum.sort(pat["permissions"]) == ["read", "write"],
             "the owner self-mint must top out at read+write; got #{inspect(pat["permissions"])}"

      refute "admin" in pat["permissions"],
             "the flat instance-wide admin bit must never be derivable from a workspace role"
    end

    test "STEP 2 — that PAT is 403 on the INSTANCE-GLOBAL run-secret it has no tenancy claim on" do
      secret_name = uniq("pat-cap-probe")
      secret_value = uniq("s3cr3t-plaintext")

      # A global-tier secret (workspace_id IS NULL). It belongs to the INSTANCE,
      # not to any workspace, and least of all to the customer's own.
      {:ok, _rec} =
        Secrets.put(secret_name, secret_value, scope: :global, actor: "pat-cap-test-setup")

      {_ws, owner} = customer_with_role("owner")
      {raw, _pat} = self_mint(owner)

      conn =
        scoped_conn()
        |> bearer(raw)
        |> get("/v1/secrets/#{secret_name}")

      # The ROUTE assertion comes first on purpose: it is the one that reds
      # with a 200 when the mint cap is reverted, which is the escalation
      # itself rather than a proxy for it.
      assert conn.status == 403,
             "a workspace owner's PAT must not clear the flat [:api, :require_admin] tier; got HTTP #{conn.status}"

      # Belt and braces: the plaintext must not leak through ANY field of the
      # refusal envelope, not merely through a `value` key.
      refute conn.resp_body =~ secret_value
    end

    test "CONTROL — a MEMBER of the same workspace still gets [\"read\"] and is 403 on the identical route" do
      secret_name = uniq("pat-cap-control")

      {:ok, _rec} =
        Secrets.put(secret_name, uniq("s3cr3t"), scope: :global, actor: "pat-cap-test-setup")

      {_ws, member} = customer_with_role("member")
      {raw, pat} = self_mint(member)

      # The member cap holds — @pat_allowed_member_permissions is not widened.
      assert pat["permissions"] == ["read"]

      conn =
        scoped_conn()
        |> bearer(raw)
        |> get("/v1/secrets/#{secret_name}")

      assert conn.status == 403
    end

    test "GRANDFATHER — existing admin rows still pass RequireAdmin: the cap is at MINT, not at CHECK" do
      # Requirement (a) of the ruling: the instance operator's PRE-EXISTING
      # ["read", "write", "admin"] credential must keep working. No migration,
      # no revoke, no backfill runs against `api_tokens`, and `RequireAdmin` is
      # untouched — so a row minted the raw/legacy way (`Auth.create_token/5`,
      # which is what the `demo` seed's `barkpark-dev-token` and every operator
      # credential came from) still clears the flat admin tier.
      #
      # NON-VACUITY: this test is the mirror of STEP 2 — same route, same
      # global secret shape, same 200-vs-403 axis. If the fix had been done at
      # the CHECK (narrowing RequireAdmin) instead of at the MINT, this test
      # would red while STEP 2 stayed green.
      secret_name = uniq("pat-cap-grandfather")
      secret_value = uniq("s3cr3t-legacy")

      {:ok, _rec} =
        Secrets.put(secret_name, secret_value, scope: :global, actor: "pat-cap-test-setup")

      ws = create_workspace!()
      raw = "legacy-admin-" <> uniq("tok")

      assert {:ok, _token} =
               Auth.create_token(
                 raw,
                 "legacy-admin",
                 "production",
                 ["read", "write", "admin"],
                 ws.id
               )

      body =
        scoped_conn()
        |> bearer(raw)
        |> get("/v1/secrets/#{secret_name}")
        |> json_response(200)

      assert body["value"] == secret_value
    end
  end
end
