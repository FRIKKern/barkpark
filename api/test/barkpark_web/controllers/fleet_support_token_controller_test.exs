defmodule BarkparkWeb.FleetSupportTokenControllerTest do
  @moduledoc """
  Contract tests for `/v1/fleet/support-tokens` (Personal Dev Fleet Wave C —
  PDF-D57/D60).

  Covers: 401 no token, 403 non-admin (both ends of the admin gate), the 201
  mint shape + one-time secret + WRITE capability + `fleet-support-<name>` label,
  and the revoke lifecycle — an HTTP request authenticated with the revoked token
  is rejected AFTERWARD (proven from a live auth attempt, never assumed from the
  DELETE 200), plus 404 on an unknown id.

  Plus the REVOKE CONFINEMENT (arpss / SECURITY): the `:require_admin` pipeline
  is instance-wide and workspace-blind, so before the guard any admin token could
  revoke ANY row in `api_tokens` by raw id — a global credential kill switch. The
  "revoke confinement" describe block proves BOTH halves independently (each with
  the other half deliberately satisfied, so neither can pass vacuously) and that
  every denial is byte-identical to a missing row.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  # NOTE: these two labels intentionally do NOT carry the `fleet-support-`
  # family prefix. They are the ACTORS, not targets; naming them in-family would
  # make the family assertions below able to pass for the wrong reason.
  @admin_token "barkpark-test-fleet-support-admin"
  @junior_token "barkpark-test-fleet-support-junior"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "fleet-admin-actor", "test", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "fleet-junior-actor", "test", ["read", "write"])
    :ok
  end

  defp admin_conn(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> @admin_token)
      |> put_req_header("content-type", "application/json")

  defp junior_conn(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> @junior_token)
      |> put_req_header("content-type", "application/json")

  defp mint(conn, name) do
    conn
    |> admin_conn()
    |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: name}))
  end

  describe "auth gating" do
    test "POST mint returns 401 without a token", %{conn: conn} do
      body = Jason.encode!(%{name: "laptop"})

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post("/v1/fleet/support-tokens", body)
             |> Map.get(:status) == 401
    end

    test "POST mint returns 403 for a non-admin token", %{conn: conn} do
      body = Jason.encode!(%{name: "laptop"})

      assert conn |> junior_conn() |> post("/v1/fleet/support-tokens", body) |> Map.get(:status) ==
               403
    end

    test "DELETE returns 401 without a token", %{conn: conn} do
      assert delete(conn, "/v1/fleet/support-tokens/whatever").status == 401
    end
  end

  describe "mint" do
    test "returns 201 with {token, token_id, name} and mints a WRITE-capable token", %{conn: conn} do
      resp = mint(conn, "build-box")
      assert resp.status == 201
      payload = Jason.decode!(resp.resp_body)

      assert payload["name"] == "build-box"
      assert is_binary(payload["token"]) and byte_size(payload["token"]) > 0
      assert is_binary(payload["token_id"]) and byte_size(payload["token_id"]) > 0

      # The returned secret is a live, WRITE-capable credential (PDF-D57: fleet
      # verbs are bearer-only, so the support must hold write).
      assert {:ok, token} = Auth.verify_token(payload["token"])
      assert token.id == payload["token_id"]
      assert Auth.has_permission?(token, "write")
      assert Auth.has_permission?(token, "read")
      # But NOT admin — a support can never mint more tokens.
      refute Auth.has_permission?(token, "admin")
      # Label convention.
      assert token.label == "fleet-support-build-box"
    end

    test "the secret is returned exactly once (never echoed on a second mint)", %{conn: conn} do
      first = mint(conn, "box-a") |> Map.get(:resp_body) |> Jason.decode!()
      second = mint(conn, "box-b") |> Map.get(:resp_body) |> Jason.decode!()

      # Each mint yields its OWN distinct secret + id — there is no retrieval path.
      assert first["token"] != second["token"]
      assert first["token_id"] != second["token_id"]
    end

    test "422 when name is missing or blank", %{conn: conn} do
      assert conn
             |> admin_conn()
             |> post("/v1/fleet/support-tokens", Jason.encode!(%{}))
             |> Map.get(:status) == 422

      assert conn
             |> admin_conn()
             |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: "   "}))
             |> Map.get(:status) == 422
    end
  end

  describe "revoke" do
    test "a request authenticated with the revoked token is REJECTED afterward", %{conn: conn} do
      minted = mint(conn, "teardown-me") |> Map.get(:resp_body) |> Jason.decode!()
      raw = minted["token"]
      token_id = minted["token_id"]

      # Before revoke: the token is a VALID credential. It is non-admin, so an
      # admin-gated call passes RequireToken and fails RequireAdmin → 403.
      before =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: "x"}))

      assert before.status == 403
      assert {:ok, _} = Auth.verify_token(raw)

      # Revoke it.
      del = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{token_id}")
      assert del.status == 200
      assert Jason.decode!(del.resp_body) == %{"token_id" => token_id, "revoked" => true}

      # After revoke: the SAME authenticated request is now rejected at
      # RequireToken → 401 (the credential is dead, not merely under-privileged).
      after_revoke =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: "x"}))

      assert after_revoke.status == 401
      assert {:error, _} = Auth.verify_token(raw)
    end

    test "DELETE on an unknown/garbage id returns 404 (not 500)", %{conn: conn} do
      assert conn
             |> admin_conn()
             |> delete("/v1/fleet/support-tokens/not-a-real-id")
             |> Map.get(:status) == 404

      assert conn
             |> admin_conn()
             |> delete("/v1/fleet/support-tokens/#{Ecto.UUID.generate()}")
             |> Map.get(:status) == 404
    end
  end

  # ── Revoke confinement (arpss / SECURITY) ────────────────────────────────
  #
  # Before the guard, `delete/2` handed the raw path id straight to the unscoped
  # `Auth.revoke_token/1`, which is a bare `Repo.get(ApiToken, uuid)`. So an
  # admin token — a gate that carries NO workspace binding — could kill any row
  # in `api_tokens`: another tenant's PAT, a share EDIT token, a chat/connector
  # token, another admin's token. Two independent checks close it; each test
  # below satisfies the OTHER check on purpose, so a single check passing both
  # tests would be caught.
  # A live, NON-support credential in the SAME workspace the admin actor
  # administers — so the workspace check passes and only FAMILY can deny.
  defp foreign_family_token do
    raw = "barkpark-test-victim-pat-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "user-pat-victim", "test", ["read", "write"])
    {raw, token}
  end

  # A live, IN-FAMILY support token bound to a DIFFERENT workspace the admin
  # actor holds no membership in — so FAMILY passes and only object authz can
  # deny.
  defp foreign_workspace_token do
    other_ws = TenancyFixtures.create_workspace!()
    raw = "barkpark-test-victim-support-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(raw, "fleet-support-other-tenant", "test", ["read", "write"], other_ws.id)

    {raw, token}
  end

  defp actor_row(raw), do: Repo.get_by!(ApiToken, token_hash: ApiToken.hash_token(raw))

  describe "revoke confinement" do
    test "an admin CANNOT revoke a token outside the fleet-support family", %{conn: conn} do
      {raw, victim} = foreign_family_token()

      # Premise: the family is the ONLY thing wrong — the actor genuinely admins
      # this row's workspace, so a family-blind guard would let this through.
      actor = actor_row(@admin_token)
      assert Barkpark.Tenancy.Auth.workspace_admin?(actor, victim.workspace_id)
      refute String.starts_with?(victim.label, "fleet-support-")

      resp = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{victim.id}")
      assert resp.status == 404

      # STATE, not the status code: the credential is still ALIVE.
      assert {:ok, _} = Auth.verify_token(raw)
      assert is_nil(Repo.get!(ApiToken, victim.id).revoked_at)
    end

    test "an admin CANNOT revoke another principal's support token in a workspace they do not admin",
         %{conn: conn} do
      {raw, victim} = foreign_workspace_token()

      # Premise: the FAMILY is correct here, so a family-only guard would let
      # this through — the workspace check is the one doing the work.
      actor = actor_row(@admin_token)
      assert String.starts_with?(victim.label, "fleet-support-")
      refute Barkpark.Tenancy.Auth.workspace_admin?(actor, victim.workspace_id)

      resp = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{victim.id}")
      assert resp.status == 404

      assert {:ok, _} = Auth.verify_token(raw)
      assert is_nil(Repo.get!(ApiToken, victim.id).revoked_at)
    end

    test "a denial is BYTE-IDENTICAL to a missing row (no existence oracle)", %{conn: conn} do
      {_raw, out_of_family} = foreign_family_token()
      {_raw2, out_of_workspace} = foreign_workspace_token()

      missing = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{Ecto.UUID.generate()}")
      garbage = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/not-a-uuid-at-all")
      family = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{out_of_family.id}")
      foreign = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{out_of_workspace.id}")

      for resp <- [missing, garbage, family, foreign] do
        assert resp.status == 404
        assert resp.resp_body == missing.resp_body
      end
    end

    test "the LEGITIMATE support revoke still succeeds end to end", %{conn: conn} do
      minted = mint(conn, "legit-box") |> Map.get(:resp_body) |> Jason.decode!()

      row = Repo.get!(ApiToken, minted["token_id"])
      assert String.starts_with?(row.label, "fleet-support-")
      assert {:ok, _} = Auth.verify_token(minted["token"])

      resp = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{minted["token_id"]}")
      assert resp.status == 200

      assert Jason.decode!(resp.resp_body) == %{
               "token_id" => minted["token_id"],
               "revoked" => true
             }

      # STATE: the credential is dead.
      refute is_nil(Repo.get!(ApiToken, minted["token_id"]).revoked_at)
      assert {:error, _} = Auth.verify_token(minted["token"])
    end
  end

  # ── The NULL-column arms of the SAME two checks (arpss) ──────────────────
  #
  # The confinement block above proves FAMILY and OBJECT AUTHZ against rows that
  # carry both columns. Neither check's fail-closed CATCH-ALL had a test, and
  # both catch-alls guard a shape that really exists in `api_tokens`:
  #
  #   * `workspace_id` is nullable and `Auth.create_token/4` predates workspace
  #     binding, so legacy support rows carry NULL. `workspace_admin?/2` denies
  #     them only because `Repo.uuid_or_nil(nil)` returns nil and the
  #     `is_binary(ws_id)` clause then misses — a fallback that reads as an
  #     accident and would be silently deleted by anyone "simplifying" the
  #     helper. If nil ever passed, EVERY unbound support row on the instance
  #     becomes revocable by ANY admin: the exact global kill switch #12700
  #     closed, reopened through the column nobody looks at.
  #   * `label` is nullable too (only `token_hash` is `validate_required`), so
  #     `support_family?/1`'s catch-all is the only thing standing between an
  #     unlabelled row and the family gate.
  #
  # Both assert STATE (the credential is still alive), not just the status code.

  # A live, IN-FAMILY support token with NO workspace binding — the legacy shape.
  # FAMILY passes on purpose, so only the object-authz nil arm can deny.
  defp null_workspace_support_token do
    raw = "barkpark-test-victim-nullws-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "fleet-support-legacy-unbound",
        dataset: "test",
        permissions: ["read", "write"],
        workspace_id: nil
      })
      |> Repo.insert()

    {raw, token}
  end

  # A live row with NO label, bound to the workspace the admin actor DOES
  # administer — so object authz passes and only the family catch-all can deny.
  defp null_label_token do
    raw = "barkpark-test-victim-nulllabel-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: nil,
        dataset: "test",
        permissions: ["read", "write"],
        workspace_id: Barkpark.Tenancy.get_default_workspace().id
      })
      |> Repo.insert()

    {raw, token}
  end

  describe "revoke confinement: the NULL-column arms" do
    test "a support-family token with a NULL workspace_id is NOT revocable", %{conn: conn} do
      {raw, victim} = null_workspace_support_token()

      # Premise: FAMILY is satisfied, so the family check cannot be what denies
      # — and the row genuinely carries no workspace, which is the whole point.
      assert String.starts_with?(victim.label, "fleet-support-")
      assert is_nil(victim.workspace_id)

      resp = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{victim.id}")
      assert resp.status == 404

      # STATE: the credential is still ALIVE.
      assert {:ok, _} = Auth.verify_token(raw)
      assert is_nil(Repo.get!(ApiToken, victim.id).revoked_at)
    end

    test "a NULL label is not in the family, even in a workspace the actor admins",
         %{conn: conn} do
      {raw, victim} = null_label_token()

      # Premise: OBJECT AUTHZ is satisfied — the actor really does admin this
      # row's workspace — so only the family catch-all can produce the denial.
      actor = actor_row(@admin_token)
      assert is_nil(victim.label)
      assert Barkpark.Tenancy.Auth.workspace_admin?(actor, victim.workspace_id)

      resp = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{victim.id}")
      assert resp.status == 404

      assert {:ok, _} = Auth.verify_token(raw)
      assert is_nil(Repo.get!(ApiToken, victim.id).revoked_at)
    end

    test "both NULL denials are BYTE-IDENTICAL to a missing row", %{conn: conn} do
      {_raw, null_ws} = null_workspace_support_token()
      {_raw2, null_label} = null_label_token()

      missing = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{Ecto.UUID.generate()}")
      unbound = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{null_ws.id}")
      unlabelled = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{null_label.id}")

      for resp <- [missing, unbound, unlabelled] do
        assert resp.status == 404
        assert resp.resp_body == missing.resp_body
      end
    end
  end
end
