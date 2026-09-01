defmodule BarkparkWeb.PatSelfMintAdminEscalationTest do
  @moduledoc """
  felix-w24-bl-pat-admin-mint-seam — REPRODUCTION, NOT A SPEC.

  ## READ THIS BEFORE TRUSTING THE GREEN

  Every assertion in this file describes behaviour that is CURRENTLY TRUE on
  `main` and that this file argues is a LIVE PRIVILEGE ESCALATION. A green run
  here is the BUG reproducing, not a contract being honoured. When the mint is
  narrowed, these tests MUST be inverted or deleted — do not "repair" them by
  loosening an assertion.

  The row that spawned this file asserted the escalation was LATENT, on the
  premise that `BarkparkWeb.AuthController.create_token/2` "hardcodes
  `permissions: ["read"]` and `role: "member"`". That premise is FALSE on
  `main`. Commit 2aa3bdb6f1 (#14245) replaced both literals with values DERIVED
  from the caller's own membership:

      {workspace_id, role} = resolve_caller_workspace(user)
      permissions = Auth.max_pat_permissions_for_role(role)

  So the sole HTTP caller now threads the caller's REAL workspace role into
  `Auth.create_personal_access_token/3`. The row's stated trigger — "a future
  caller threads ... the minter's real workspace role" — already happened.

  ## The chain, proven below in two steps

    1. A user who is `owner` (or `admin`) of ANY workspace — including one they
       created themselves, since `Tenancy.do_create_owned_workspace/4` writes
       the human behind the creating token a second `"owner"` membership row —
       POSTs `/v1/auth/tokens` and receives a PAT carrying the FLAT `"admin"`
       permission.
    2. `BarkparkWeb.Plugs.RequireAdmin` is `Auth.has_permission?(token, "admin")`,
       i.e. `"admin" in token.permissions` — unscoped, workspace-blind. So the
       token from step 1 clears every `[:api, :require_admin]` route. This file
       drives ONE of them: `GET /v1/secrets/:name`, the INSTANCE-GLOBAL
       (`workspace_id IS NULL`) run-secret store, which returns plaintext.

  The control test proves the gate is otherwise real: a `member` of the same
  workspace self-mints and is 403 on the identical route. Owner → 200,
  member → 403, same request shape, same route: the workspace ROLE is what
  carries the caller through an instance-global admin gate.

  ## Caller table — every caller of `Auth.create_personal_access_token/3`

  Sweep: `grep -rn "create_personal_access_token" <repo>` (excluding
  `_build/`, `deps/`, `node_modules/`, `.git/`). Call sites only; comments and
  `@doc` mentions excluded. This CLOSES the row's "UNCLOSED EDGE" (Studio
  LiveView panes and mix tasks were never audited): there are none.

  | Call site | Threads a client-supplied permission list? | Threads the caller's REAL workspace role? |
  |---|---|---|
  | `api/lib/barkpark_web/controllers/auth_controller.ex:311` (`create_token/2`, `POST /v1/auth/tokens`) | NO — `params` is read for `:name` only; a body `role`/`permissions`/`owner_user_id` is ignored | **YES** — `role` comes from `TenancyAuth.membership_role/2` via `resolve_caller_workspace/1`, and `permissions` is `Auth.max_pat_permissions_for_role(role)`. **This is the live escalation.** |
  | Studio LiveView panes (`live/studio/**`, `studio_chrome.ex`) | — | **NO CALL EXISTS.** Zero hits repo-wide. They call `Tenancy.create_workspace_with_owner/2`, never the PAT mint. |
  | `api/lib/mix/tasks/**` | — | **NO CALL EXISTS.** Zero hits across all 33 mix tasks. |
  | `api/priv/**` | — | **NO CALL EXISTS.** Zero hits. |
  | `cloud/lib/barkpark_cloud/accounts.ex:930` | separate function in a separate OTP app (`BarkparkCloud.Accounts`), not this one | out of scope for this row; its own role gate is at `accounts.ex:838` |

  Two stale comments assert the retired hardcode and should be corrected out of
  band (outside this task's fence): `api/lib/barkpark/media/blobstore/s3.ex:146`
  and `api/lib/barkpark/media/blobstore/local.ex:74` both still say the sole
  caller "hardcodes `["read"]`".

  ## Why no `["read"]`-only pin was added

  The row asked for a test asserting the mint issues `["read"]` regardless of
  role. Such a test would contradict THREE existing green pins that record the
  present behaviour as intended:

    * `test/barkpark_web/controllers/access_token_identity_test.exs` case 12,
      "an owner self-mints up to [\\"read\\", \\"write\\", \\"admin\\"]"
    * the same file's admin twin
    * `test/barkpark/auth_test.exs` "an admin/owner may mint write + admin tokens"

  and would contradict the `create_token/2` `@doc`'s "(Option A, lead-ratified
  2026-08-24)". Narrowing `@pat_allowed_admin_permissions` would red all three.
  The escalation is therefore reported for RE-PRICING, not silently fixed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
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

  # Self-mint over the REAL HTTP route, as the session user — the vulnerable
  # surface. Returns {raw_token, personal_access_token_json}.
  defp self_mint(user) do
    conn =
      build_conn()
      |> bearer(user_bearer(user))
      |> post("/v1/auth/tokens", %{"name" => uniq("cli")})

    assert %{"token" => raw, "personal_access_token" => pat} = json_response(conn, 201)
    {raw, pat}
  end

  # A user holding `role` in a FRESH workspace of their own — the shape of an
  # ordinary customer, with no instance-level privilege of any kind.
  defp customer_with_role(role) do
    ws = create_workspace!()
    user = register_user(uniq_email("pat-esc-#{role}"))
    {:ok, _membership} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    {ws, user}
  end

  describe "the HTTP PAT self-mint hands a customer workspace owner a flat admin token" do
    test "STEP 1 — an owner's self-minted PAT carries the flat \"admin\" permission" do
      {_ws, owner} = customer_with_role("owner")

      {_raw, pat} = self_mint(owner)

      # ESCALATION REPRODUCTION: this green is the defect. `"admin"` here is
      # the unscoped permission `RequireAdmin` checks — see STEP 2.
      assert "admin" in pat["permissions"],
             "expected the owner self-mint to (wrongly) grant flat admin; got #{inspect(pat["permissions"])}"
    end

    test "STEP 2 — that PAT reveals an INSTANCE-GLOBAL run-secret it has no tenancy claim on" do
      secret_name = uniq("pat-escalation-probe")
      secret_value = uniq("s3cr3t-plaintext")

      # A global-tier secret (workspace_id IS NULL). It belongs to the INSTANCE,
      # not to any workspace, and least of all to the customer's own.
      {:ok, _rec} =
        Secrets.put(secret_name, secret_value, scope: :global, actor: "escalation-test-setup")

      {_ws, owner} = customer_with_role("owner")
      {raw, pat} = self_mint(owner)
      assert "admin" in pat["permissions"]

      body =
        build_conn()
        |> bearer(raw)
        |> get("/v1/secrets/#{secret_name}")
        |> json_response(200)

      # ESCALATION REPRODUCTION: a customer workspace owner reads instance
      # plaintext. `RequireAdmin` is workspace-blind (`"admin" in
      # token.permissions`), so the flat `/v1/secrets` tier — and every other
      # `[:api, :require_admin]` route that does not re-bind tenancy in its
      # action — is open to this token.
      assert body["value"] == secret_value,
             "expected the owner-minted PAT to (wrongly) reveal the global secret"
    end

    test "CONTROL — a MEMBER of the same workspace is 403 on the identical route" do
      secret_name = uniq("pat-escalation-control")

      {:ok, _rec} =
        Secrets.put(secret_name, uniq("s3cr3t"), scope: :global, actor: "escalation-test-setup")

      {_ws, member} = customer_with_role("member")
      {raw, pat} = self_mint(member)

      # The member cap holds — @pat_allowed_member_permissions is not widened.
      assert pat["permissions"] == ["read"]

      conn =
        build_conn()
        |> bearer(raw)
        |> get("/v1/secrets/#{secret_name}")

      # NON-VACUITY: the admin gate is real and does refuse. The ONLY difference
      # between this 403 and STEP 2's 200 is the caller's workspace role — which
      # is exactly what makes STEP 2 an escalation rather than a stale route.
      assert conn.status == 403
    end
  end
end
