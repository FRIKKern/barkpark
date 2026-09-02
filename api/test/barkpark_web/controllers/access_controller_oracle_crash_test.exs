defmodule BarkparkWeb.AccessControllerOracleCrashTest do
  @moduledoc """
  Two defects at the airdrop-grant surface, pinned together because they share
  one file (`BarkparkWeb.AccessController`).

  ## 1. The existence oracle (`arpss-w8-bl-access-grant-id-existence-oracle`)

  `GET|DELETE /v1/access/:id` used to answer **403** for a grant id that EXISTS
  but belongs to another tenant, and **404** for one that does not exist. The
  status split told an unauthenticated-in-that-workspace caller whether an
  opaque row id was real — an enumeration oracle over another tenant's grant
  ids, and the one genuine counter-example to the denial-shape law in
  `BarkparkWeb.ShareLinkController`'s moduledoc.

  The fix narrows the oracle WITHOUT collapsing the real authorization signal:

    * grant missing ....................................... 404
    * grant exists, caller cannot even `:read` its
      workspace (FOREIGN tenant) .......................... 404 ← same bytes
    * grant exists, caller may read the workspace but is
      neither grantor nor admin (IN-tenant) ............... 403 ← preserved

  So the tests below assert the two 404 arms are **byte-identical**, and that
  the in-tenant 403 survives.

  ## 2. The reachable crash (`task-5275ac6f76e3b93d`)

  A MALFORMED (non-UUID) `workspace_id` reached `Barkpark.Tenancy.Auth.authorize/3`,
  whose arm guards check only `is_binary/1`, and bound a non-UUID string to a
  `:binary_id` column — `Ecto.Query.CastError` on an authorization check, on
  both `GET /v1/access?workspace_id=` and the credential-MINTING
  `POST /v1/access`.

  That crash is ALREADY CLOSED on main, transitively and exactly as the task
  predicted: `authorize/3` inherits totality for malformed ids from its
  `membership/2` seam (which routes both ids through `Repo.uuid_or_nil/1`), so
  both endpoints now answer **403**. These tests are the REGRESSION PIN for
  that — the controller is the layer that could re-open it by resolving a
  workspace id itself.

  The 403 (rather than a 422 "malformed" body) is the recorded disposition:
  splitting malformed from unauthorized would re-open the same kind of
  information channel section 1 closes, so every unusable `workspace_id` —
  malformed, nonexistent, or merely not yours — answers alike, asserted
  byte-for-byte below.

  Note the PATH id was never affected: `Access.get_grant/1` is UUID-guarded via
  `Repo.uuid_or_nil/1`, and `access_controller_test.exs` already pins
  `GET /v1/access/not-a-uuid` → 404.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Access
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # An API-token principal with a chosen permission set, made a member of `ws`.
  # For the ApiToken arm of `Auth.authorize/3` the PERMISSIONS cap the action
  # (`member?/2 and permits?/2`), so `["read"]` is an in-tenant reader that is
  # NOT an admin — exactly the "can see it, may not manage it" principal.
  defp token_principal(ws, permissions, role \\ "admin") do
    raw = "t-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "principal",
        dataset: "test",
        permissions: permissions
      })
      |> Repo.insert()

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
    {raw, token}
  end

  # A bare token with NO membership anywhere.
  defp stranger_token do
    raw = "s-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "stranger", "test", ["read", "write", "admin"])
    raw
  end

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp mint_grant(ws, grantee_email) do
    {_raw, grantor} = token_principal(ws, ["admin"])

    {:ok, %{grant: grant}} =
      Access.mint(grantor, %{
        grantee_email: grantee_email,
        workspace_id: ws.id,
        capabilities: ["read"]
      })

    grant
  end

  # ── 1. the existence oracle — GET /v1/access/:id ────────────────────────────

  describe "GET /v1/access/:id — foreign vs missing are indistinguishable" do
    test "a FOREIGN grant id and a MISSING id answer byte-identical 404s", %{conn: _conn} do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      # A real grant living in workspace B — an opaque id that EXISTS.
      foreign = mint_grant(ws_b, "b@example.com")

      # The probe is a full admin in workspace A, and a nobody in B.
      {probe_raw, _} = token_principal(ws_a, ["read", "write", "admin"])

      missing_id = Ecto.UUID.generate()

      foreign_conn = build_conn() |> bearer(probe_raw) |> get("/v1/access/#{foreign.id}")
      missing_conn = build_conn() |> bearer(probe_raw) |> get("/v1/access/#{missing_id}")

      assert foreign_conn.status == 404
      assert missing_conn.status == 404

      # Byte-identical, not merely same-status: ONE not_found/1 call site.
      assert foreign_conn.resp_body == missing_conn.resp_body
      assert json_response(foreign_conn, 404)["error"]["code"] == "not_found"
    end

    test "a stranger with no membership anywhere also gets the missing-id 404", %{conn: _conn} do
      ws = create_workspace!()
      grant = mint_grant(ws, "g@example.com")
      stranger = stranger_token()

      real = build_conn() |> bearer(stranger) |> get("/v1/access/#{grant.id}")
      missing = build_conn() |> bearer(stranger) |> get("/v1/access/#{Ecto.UUID.generate()}")

      assert real.status == 404
      assert real.resp_body == missing.resp_body
    end

    # The narrowing must NOT blanket-404 everything: a caller who legitimately
    # sees the workspace still gets the real authorization signal.
    test "an IN-TENANT non-manager keeps its 403 (the signal is preserved)", %{conn: conn} do
      ws = create_workspace!()
      grant = mint_grant(ws, "g@example.com")

      # Member of the grant's workspace, may :read it, is neither grantor nor admin.
      {reader_raw, _} = token_principal(ws, ["read"])

      conn = conn |> bearer(reader_raw) |> get("/v1/access/#{grant.id}")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # POSITIVE CONTROL — the authorized path is untouched.
    test "the workspace admin still reads the grant → 200", %{conn: conn} do
      ws = create_workspace!()
      {admin_raw, _} = token_principal(ws, ["read", "write", "admin"])
      grant = mint_grant(ws, "g@example.com")

      conn = conn |> bearer(admin_raw) |> get("/v1/access/#{grant.id}")
      assert json_response(conn, 200)["grant"]["id"] == grant.id
    end
  end

  # ── 2. the existence oracle — DELETE /v1/access/:id ─────────────────────────

  describe "DELETE /v1/access/:id — foreign vs missing are indistinguishable" do
    test "a FOREIGN grant id and a MISSING id answer byte-identical 404s", %{conn: _conn} do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      foreign = mint_grant(ws_b, "b@example.com")
      {probe_raw, _} = token_principal(ws_a, ["read", "write", "admin"])

      foreign_conn = build_conn() |> bearer(probe_raw) |> delete("/v1/access/#{foreign.id}")

      missing_conn =
        build_conn() |> bearer(probe_raw) |> delete("/v1/access/#{Ecto.UUID.generate()}")

      assert foreign_conn.status == 404
      assert missing_conn.status == 404
      assert foreign_conn.resp_body == missing_conn.resp_body
      assert json_response(foreign_conn, 404)["error"]["code"] == "not_found"

      # And the probe did NOT revoke another tenant's grant on the way out.
      assert is_nil(Repo.reload!(foreign).revoked_at)
    end

    test "an IN-TENANT non-manager keeps its 403 on revoke", %{conn: conn} do
      ws = create_workspace!()
      grant = mint_grant(ws, "g@example.com")
      {reader_raw, _} = token_principal(ws, ["read"])

      conn = conn |> bearer(reader_raw) |> delete("/v1/access/#{grant.id}")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # POSITIVE CONTROL — the real grantor/admin still revokes.
    test "the workspace admin still revokes → 200", %{conn: conn} do
      ws = create_workspace!()
      {admin_raw, _} = token_principal(ws, ["read", "write", "admin"])
      grant = mint_grant(ws, "g@example.com")

      conn = conn |> bearer(admin_raw) |> delete("/v1/access/#{grant.id}")
      assert json_response(conn, 200)["grant"]["id"] == grant.id
      refute is_nil(Repo.reload!(grant).revoked_at)
    end
  end

  # ── 3. the reachable crash — malformed workspace_id ─────────────────────────

  describe "a MALFORMED workspace_id is a clean denial, never a crash" do
    test "GET /v1/access?workspace_id=zzz → 403 in the canonical envelope", %{conn: conn} do
      ws = create_workspace!()
      {member_raw, _} = token_principal(ws, ["read", "write", "admin"])

      conn = conn |> bearer(member_raw) |> get("/v1/access", %{"workspace_id" => "zzz"})

      # A DENIAL, not an Ecto.Query.CastError escaping to the router.
      assert conn.status == 403
      body = json_response(conn, 403)
      assert body["error"]["code"] == "forbidden"
      # The canonical envelope, not a stacktrace payload.
      assert Map.keys(body) == ["error"]
    end

    # The malformed answer must be the SAME answer an unusable-but-well-formed
    # workspace_id gets, or "is this string even a UUID" becomes its own
    # side channel.
    test "malformed and nonexistent workspace_id are byte-identical on GET", %{conn: _conn} do
      ws = create_workspace!()
      {member_raw, _} = token_principal(ws, ["read", "write", "admin"])

      malformed =
        build_conn() |> bearer(member_raw) |> get("/v1/access", %{"workspace_id" => "zzz"})

      nonexistent =
        build_conn()
        |> bearer(member_raw)
        |> get("/v1/access", %{"workspace_id" => Ecto.UUID.generate()})

      assert malformed.status == 403
      assert malformed.resp_body == nonexistent.resp_body
    end

    test "POST /v1/access with a malformed workspace_id → 403, never a CastError", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "grantee@example.com",
          "workspace_id" => "zzz",
          "capabilities" => ["read"]
        })

      assert conn.status == 403
      body = json_response(conn, 403)
      assert body["error"]["code"] == "forbidden"
      assert Map.keys(body) == ["error"]
    end

    # The mint surface reaches the crash site only with a NON-EMPTY capability
    # list (`authorize_capabilities/3` guards `caps != []`), so an empty list
    # would probe nothing. Pinned so the arm above cannot go vacuous.
    test "the mint probe carries capabilities, so it reaches the authorize seam", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write"])

      # Same request, WELL-FORMED but foreign workspace: also 403, proving the
      # capability list is what drives the call into Tenancy.Auth.
      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "grantee@example.com",
          "workspace_id" => Ecto.UUID.generate(),
          "capabilities" => ["read"]
        })

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # The guard must not swallow the MISSING case, which has its own contract.
    test "a MISSING workspace_id keeps its existing answers", %{conn: _conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write", "admin"])

      list = build_conn() |> bearer(grantor_raw) |> get("/v1/access")
      assert json_response(list, 422)["error"]["message"] == "workspace_id is required"

      mint =
        build_conn()
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "g@example.com",
          "capabilities" => ["read"]
        })

      assert json_response(mint, 403)["error"]["code"] == "forbidden"
    end
  end

  # ── 4. the index third variant — a recorded DISPOSITION ─────────────────────

  # `AccessController.index/2` answers 403 for a well-formed workspace_id that
  # is merely NONEXISTENT, without ever resolving the workspace. That is the
  # ACCEPTED signal, not a defect: folding "no such workspace" into the same
  # 403 as "not yours" is precisely the no-oracle shape — the caller cannot
  # tell a real workspace it lacks access to from one that was never there.
  # Pinned so the equivalence is a contract rather than an accident.
  test "index: a NONEXISTENT workspace_id is byte-identical to an UNAUTHORIZED one", %{
    conn: _conn
  } do
    ws_real = create_workspace!()
    stranger = stranger_token()

    unauthorized =
      build_conn() |> bearer(stranger) |> get("/v1/access", %{"workspace_id" => ws_real.id})

    nonexistent =
      build_conn()
      |> bearer(stranger)
      |> get("/v1/access", %{"workspace_id" => Ecto.UUID.generate()})

    assert unauthorized.status == 403
    assert nonexistent.status == 403
    assert unauthorized.resp_body == nonexistent.resp_body
  end
end
