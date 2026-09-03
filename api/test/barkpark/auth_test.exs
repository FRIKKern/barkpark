defmodule Barkpark.AuthTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy

  defp workspace(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Auth WS"})
    ws
  end

  # Insert a token with a known raw value so verify_token/1 can be exercised.
  # `attrs` overlays extra fields (revoked_at / expires_at / workspace_id).
  defp insert_token(raw, attrs \\ %{}) do
    base = %{
      token_hash: ApiToken.hash_token(raw),
      label: "l",
      dataset: "test",
      permissions: ["read"]
    }

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    token
  end

  defp seconds_from_now(secs) do
    DateTime.utc_now() |> DateTime.add(secs, :second) |> DateTime.truncate(:second)
  end

  describe "verify_token/1 — base behaviour" do
    test "an active token verifies (no regression)" do
      raw = "active-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      assert {:ok, verified} = Auth.verify_token(raw)
      assert verified.id == token.id
    end

    test "an unknown token is unauthorized" do
      assert Auth.verify_token("nope-" <> Ecto.UUID.generate()) == {:error, :unauthorized}
    end
  end

  describe "verify_token/1 — revocation" do
    test "a revoked token is rejected (was: authenticated)" do
      raw = "revoked-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      # Sanity: verifies before revocation.
      assert {:ok, _} = Auth.verify_token(raw)

      assert {:ok, _} = Auth.revoke_token(token)
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end
  end

  describe "verify_token/1 — expiry" do
    test "an expired token (expires_at in the past) is rejected" do
      raw = "expired-" <> Ecto.UUID.generate()
      insert_token(raw, %{expires_at: seconds_from_now(-60)})

      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end

    test "a non-expired token (expires_at in the future) still verifies" do
      raw = "future-" <> Ecto.UUID.generate()
      token = insert_token(raw, %{expires_at: seconds_from_now(3600)})

      assert {:ok, verified} = Auth.verify_token(raw)
      assert verified.id == token.id
    end

    test "a nil expires_at never expires" do
      raw = "nilexp-" <> Ecto.UUID.generate()
      insert_token(raw, %{expires_at: nil})

      assert {:ok, _} = Auth.verify_token(raw)
    end
  end

  describe "revoke_token/1" do
    test "stamps revoked_at and accepts a struct" do
      token = insert_token("rt-struct-" <> Ecto.UUID.generate())
      assert is_nil(token.revoked_at)

      assert {:ok, revoked} = Auth.revoke_token(token)
      refute is_nil(revoked.revoked_at)
    end

    test "accepts a token id" do
      raw = "rt-id-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      assert {:ok, revoked} = Auth.revoke_token(token.id)
      assert revoked.id == token.id
      refute is_nil(revoked.revoked_at)
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end

    test "unknown id → {:error, :not_found}" do
      assert Auth.revoke_token(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "emits a token/token_revoked audit event" do
      token = insert_token("rt-audit-" <> Ecto.UUID.generate())
      assert {:ok, revoked} = Auth.revoke_token(token)

      import Ecto.Query
      ev = Barkpark.Repo.one(from e in Barkpark.Audit.Event, where: e.action == "token_revoked")
      assert ev.category == "token"
      assert ev.subject == revoked.id
    end
  end

  # A USER-shaped login ticket carries the email its consume JIT-provisions.
  # `consume_login_ticket/1` burns the single-use row FIRST, so an address the
  # registration changeset would reject used to mint a 201 ticket and then make
  # `Sso.find_or_create_user/1` raise (500) with the ticket permanently spent.
  # The refusal belongs at the mint, in the existing no-oracle error shape.
  describe "mint_login_ticket/2 — user_email format" do
    test "a malformed user_email is refused with {:error, :unauthorized}" do
      raw = "mlt-bad-" <> Ecto.UUID.generate()
      insert_token(raw, %{permissions: ["read", "admin"]})

      assert Auth.mint_login_ticket(raw, user_email: "not-an-email") ==
               {:error, :unauthorized}

      assert Auth.mint_login_ticket(raw, user_email: "has space@example.com") ==
               {:error, :unauthorized}

      # ...and no ticket row was written for the refused mint.
      assert Barkpark.Repo.aggregate(Barkpark.Auth.LoginTicket, :count) == 0
    end

    test "a well-formed user_email mints and consumes end to end" do
      raw = "mlt-good-" <> Ecto.UUID.generate()
      insert_token(raw, %{permissions: ["read", "admin"]})

      assert {:ok, ticket} = Auth.mint_login_ticket(raw, user_email: "someone@example.com")
      assert String.starts_with?(ticket, "bplt_")

      assert Auth.consume_login_ticket(ticket) ==
               {:ok, {:user, "someone@example.com", raw}}

      # single-use still holds
      assert Auth.consume_login_ticket(ticket) == {:error, :invalid}
    end

    test "a token-shaped ticket (no user_email) is unaffected" do
      raw = "mlt-plain-" <> Ecto.UUID.generate()
      insert_token(raw)

      assert {:ok, ticket} = Auth.mint_login_ticket(raw)
      assert Auth.consume_login_ticket(ticket) == {:ok, raw}
    end
  end

  # nil-permissions guard (omhr). has_permission?/2 evaluated `permission in
  # token.permissions`; a token with nil permissions raised ArgumentError
  # instead of denying. Reachable from RequireAdmin + media-access checks.
  describe "has_permission?/2 — nil permissions deny (not raise)" do
    test "a token with nil permissions returns false (was: raised)" do
      token = %ApiToken{permissions: nil}

      refute Auth.has_permission?(token, "admin")
      refute Auth.has_permission?(token, "write")
      refute Auth.has_permission?(token, "read")
    end

    test "the unguarded `permission in nil` form would have raised pre-fix" do
      # `permission in token.permissions` with nil permissions raises (the
      # pre-fix form); the `|| []` coercion makes the call total. The raise is a
      # Protocol.UndefinedError from Enumerable on this Elixir — the class is
      # incidental, the RAISE is the hazard the guard closes.
      assert_raise Protocol.UndefinedError, fn -> "admin" in nil end
    end

    test "REGRESSION: a normal token still reports its permissions" do
      token = %ApiToken{permissions: ["read", "write"]}

      assert Auth.has_permission?(token, "read")
      assert Auth.has_permission?(token, "write")
      refute Auth.has_permission?(token, "admin")
    end
  end

  describe "deleted-workspace orphan (cascade)" do
    test "deleting a token's home workspace deletes the token (no orphan auth)" do
      ws = workspace("ws-cascade")
      raw = "cascade-" <> Ecto.UUID.generate()

      {:ok, token} = Auth.create_token(raw, "l", "test", ["read", "write", "admin"], ws.id)
      assert token.workspace_id == ws.id
      assert {:ok, _} = Auth.verify_token(raw)

      # Delete the home workspace — the FK cascade must take the token with it.
      Repo.delete!(ws)

      assert is_nil(Repo.get(ApiToken, token.id))
      # The orphan vector is closed: a token whose workspace is gone no longer
      # authenticates (previously it persisted with workspace_id NULL).
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end
  end

  describe "create_personal_access_token/3 — role gating + shape" do
    test "a member may mint a read token; plaintext is prefixed + shown once" do
      assert {:ok, {raw, token}} =
               Auth.create_personal_access_token("ci-read", ["read"],
                 role: "member",
                 created_by: "admin@example.com"
               )

      assert String.starts_with?(raw, "bppat_")
      assert token.name == "ci-read"
      assert token.created_by == "admin@example.com"
      assert token.permissions == ["read"]
      assert token.token_hash == ApiToken.hash_token(raw)
      # The raw token round-trips through verify_token/1.
      assert {:ok, _} = Auth.verify_token(raw)
    end

    test "a member may NOT mint write/admin (forbidden)" do
      assert {:error, :forbidden} =
               Auth.create_personal_access_token("ci-write", ["write"], role: "member")

      assert {:error, :forbidden} =
               Auth.create_personal_access_token("ci-admin", ["admin"], role: "member")
    end

    test "an admin/owner may mint WRITE — but \"admin\" is forbidden at every role (the flat bit is instance-wide, ruling 2026-09-02)" do
      assert {:ok, {_raw, wt}} =
               Auth.create_personal_access_token("rw", ["read", "write"], role: "admin")

      assert "write" in wt.permissions
      refute "admin" in wt.permissions

      # INVERTED 2026-09-02 (orchestrator ruling A, delegated; owner informed
      # 2026-09-01). This used to assert an `owner` COULD mint
      # ["read", "write", "admin"]. `"admin"` is the flat, instance-wide
      # permission `BarkparkWeb.Plugs.RequireAdmin` reads workspace-blind, so
      # deriving it from a workspace role handed any workspace owner the whole
      # instance. @pat_allowed_elevated_permissions now tops out at `write`,
      # and this is the SAME allowed set `max_pat_permissions_for_role/1`
      # publishes — an explicit request is refused, not silently trimmed.
      assert {:error, :forbidden} =
               Auth.create_personal_access_token("root", ["read", "write", "admin"],
                 role: "owner"
               )

      assert {:error, :forbidden} =
               Auth.create_personal_access_token("root-admin-only", ["admin"], role: "owner")

      assert Auth.max_pat_permissions_for_role("owner") == ["read", "write"]
      assert Auth.max_pat_permissions_for_role("admin") == ["read", "write"]
    end

    test "an empty permission set is rejected" do
      assert {:error, :forbidden} =
               Auth.create_personal_access_token("empty", [], role: "owner")
    end

    test "default expiry is ~30 days; :ttl nil means never" do
      {:ok, {_raw, default_tok}} =
        Auth.create_personal_access_token("default-exp", ["read"], role: "member")

      assert default_tok.expires_at
      days = DateTime.diff(default_tok.expires_at, DateTime.utc_now(), :second) / 86_400
      assert_in_delta days, 30, 1

      {:ok, {_raw2, never_tok}} =
        Auth.create_personal_access_token("never-exp", ["read"], role: "member", ttl: nil)

      assert is_nil(never_tok.expires_at)
    end

    test "ttl is capped at one year" do
      {:ok, {_raw, tok}} =
        Auth.create_personal_access_token("huge-ttl", ["read"],
          role: "member",
          ttl: 10 * 365 * 24 * 3600
        )

      days = DateTime.diff(tok.expires_at, DateTime.utc_now(), :second) / 86_400
      assert days <= 366
    end
  end

  # relabel_token/2 (connectors D179). The Add-to-Slack flow mints its chat token
  # as `connector:slack:oauth` BEFORE the callback knows the team_id; once the
  # install lands, the label is reconciled to `connector:slack:<install_key>` so
  # disconnect rides the single install_key path. A plain label update, never a
  # revoke — the credential the install is using must stay live.
  describe "relabel_token/2 — connector oauth→install_key reconciliation" do
    test "updates the label in place, stays live, and still authenticates" do
      ws = workspace("ws-relabel")

      {:ok, raw, token} =
        Auth.create_chat_token("connector:slack:oauth", "production", ws.id)

      assert token.label == "connector:slack:oauth"

      assert {:ok, r1} = Auth.relabel_token(token, "connector:slack:T_TEAM")
      assert r1.label == "connector:slack:T_TEAM"
      # Relabel ≠ revoke: the token is still live and still verifies under its raw.
      assert is_nil(r1.revoked_at)
      assert {:ok, verified} = Auth.verify_token(raw)
      assert verified.id == token.id
    end

    test "is idempotent — relabelling to the current label is a clean no-op update" do
      ws = workspace("ws-relabel-idem")

      {:ok, _raw, token} =
        Auth.create_chat_token("connector:slack:T_TEAM", "production", ws.id)

      assert {:ok, r} = Auth.relabel_token(token, "connector:slack:T_TEAM")
      assert r.label == "connector:slack:T_TEAM"
      assert is_nil(r.revoked_at)
    end
  end

  describe "touch_last_used/1 — throttled liveness stamp" do
    test "stamps last_used_at; a quick re-touch is throttled" do
      raw = "touch-" <> Ecto.UUID.generate()
      token = insert_token(raw)
      assert is_nil(token.last_used_at)

      :ok = Auth.touch_last_used(token)
      first = Repo.get(ApiToken, token.id).last_used_at
      assert first

      # Re-touch with the now-stamped struct within the throttle window: no move.
      reloaded = Repo.get(ApiToken, token.id)
      :ok = Auth.touch_last_used(reloaded)
      assert Repo.get(ApiToken, token.id).last_used_at == first
    end
  end
end
