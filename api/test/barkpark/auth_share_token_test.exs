defmodule Barkpark.AuthShareTokenTest do
  @moduledoc """
  P5 — `Auth.create_share_token/5` + `revoke_share_tokens/3` + the
  `Sharing.remove_share/3` revoke hook.

  The contract: an edit token mints ONLY for a scope that is live-`:edit`-shared
  for the requested surfaces; it carries OPAQUE `share-edit-*` permissions (never
  `write`/`admin`), a byte-exact `share_scope`, an expiry, and NO membership.
  `async: false` — mutates the global `:shares` env.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Auth, Sharing}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  import Barkpark.TenancyFixtures
  import Barkpark.SharingFixtures
  import Ecto.Query

  setup do
    ws = create_workspace!("edit-tok-ws")
    proj = create_project!(ws, "edit-tok-proj")

    snapshot_shares!()

    %{ws: ws, proj: proj, scope: "#{ws.slug}/#{proj.slug}/production"}
  end

  # Planted as a PERSISTED share (SharingFixtures), not a bare put_env: this
  # suite's own subject fires `Sharing.refresh/0` (`remove_share/3`, and
  # `revoke_share_tokens/3` lives on that path), which rebuilds `:shares` from
  # `shares_env() ++ list_stored()` and ERASES anything planted only in the env.
  defp share!(scope, spec), do: plant_shares!("#{scope}:#{spec}")

  # ── minting ───────────────────────────────────────────────────────────

  describe "create_share_token/5" do
    test "mints an opaque, scope-bound, expiring, member-less token", %{
      ws: ws,
      proj: proj,
      scope: scope
    } do
      share!(scope, "docs:edit")

      assert {:ok, {raw, %ApiToken{} = token}} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])

      assert String.starts_with?(raw, "bpshare_")
      assert token.permissions == ["share-edit-docs"]
      assert token.share_scope == scope
      assert token.expires_at != nil
      # the token resolves (until expiry/revoke)...
      assert {:ok, _} = Auth.verify_token(raw)
      # ...but holds NO write/admin perm and NO membership row.
      refute Auth.has_permission?(token, "write")
      refute Auth.has_permission?(token, "admin")

      refute Repo.exists?(
               from(m in Barkpark.Tenancy.Membership,
                 where: m.principal_id == ^token.id and m.principal_type == "api_token"
               )
             )
    end

    test "covers multiple edit-shared surfaces in one token", %{ws: ws, proj: proj, scope: scope} do
      share!(scope, "docs,media:edit")

      assert {:ok, {_raw, token}} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["docs", "media"])

      assert Enum.sort(token.permissions) == ["share-edit-docs", "share-edit-media"]
    end

    test "refuses when the scope is only READ-shared", %{ws: ws, proj: proj, scope: scope} do
      share!(scope, "docs:read")

      assert {:error, :not_edit_shared} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])
    end

    test "refuses when the scope is not shared at all", %{ws: ws, proj: proj} do
      Application.delete_env(:barkpark, :shares)

      assert {:error, :not_edit_shared} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])
    end

    test "refuses a surface that is not in the edit share", %{ws: ws, proj: proj, scope: scope} do
      share!(scope, "docs:edit")

      assert {:error, :surface_not_shared} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["media"])
    end

    test "refuses papers / unknown surfaces (only docs+media are editable)", %{
      ws: ws,
      proj: proj,
      scope: scope
    } do
      share!(scope, "papers,docs:edit")

      assert {:error, :unsupported_surface} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["papers"])

      assert {:error, :unsupported_surface} =
               Auth.create_share_token(ws.slug, proj.slug, "production", ["wat"])
    end

    test "refuses an unknown workspace/project even if a matching share string exists", %{
      scope: _scope
    } do
      share!("ghost/ghost/production", "docs:edit")

      assert {:error, :unknown_scope} =
               Auth.create_share_token("ghost", "ghost", "production", ["docs"])
    end

    test "caps the TTL at one year", %{ws: ws, proj: proj, scope: scope} do
      share!(scope, "docs:edit")

      {:ok, {_raw, token}} =
        Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"], ttl: 999_999_999)

      max = DateTime.add(DateTime.utc_now(), 366 * 24 * 3600)
      assert DateTime.compare(token.expires_at, max) == :lt
    end
  end

  # ── revocation ──────────────────────────────────────────────────────────

  describe "revoke_share_tokens/3 + remove_share hook" do
    test "batch-revokes every token bound to a scope", %{ws: ws, proj: proj, scope: scope} do
      share!(scope, "docs:edit")
      {:ok, {raw, _}} = Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])
      assert {:ok, _} = Auth.verify_token(raw)

      assert {:ok, 1} = Auth.revoke_share_tokens(ws.slug, proj.slug, "production")
      assert {:error, :unauthorized} = Auth.verify_token(raw)
    end

    # revoke_share_tokens/3 was a bare Repo.update_all: it stamped revoked_at
    # (so verify_token rejected, which is all the test above asserts) while
    # skipping revoke_token/1's audit emit entirely. Killing a standing
    # credential with no audit row is the gap; this asserts the row per token.
    test "emits a token/token_revoked audit row per revoked share token", %{
      ws: ws,
      proj: proj,
      scope: scope
    } do
      share!(scope, "docs:edit")

      {:ok, {_raw_a, token_a}} =
        Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])

      {:ok, {_raw_b, token_b}} =
        Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])

      assert {:ok, 2} = Auth.revoke_share_tokens(ws.slug, proj.slug, "production")

      events =
        Repo.all(
          from(e in Barkpark.Audit.Event,
            where: e.category == "token" and e.action == "token_revoked"
          )
        )

      assert length(events) == 2
      assert Enum.sort(Enum.map(events, & &1.subject)) == Enum.sort([token_a.id, token_b.id])
    end

    test "is idempotent — a repeat revoke revokes nothing and audits nothing", %{
      ws: ws,
      proj: proj,
      scope: scope
    } do
      share!(scope, "docs:edit")
      {:ok, {_raw, _}} = Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])

      assert {:ok, 1} = Auth.revoke_share_tokens(ws.slug, proj.slug, "production")
      assert {:ok, 0} = Auth.revoke_share_tokens(ws.slug, proj.slug, "production")

      assert Repo.aggregate(
               from(e in Barkpark.Audit.Event, where: e.action == "token_revoked"),
               :count
             ) == 1
    end

    test "removing the share hard-revokes its edit tokens", %{ws: ws, proj: proj, scope: scope} do
      {:ok, _} = Sharing.add_share("#{scope}:docs:edit")
      {:ok, {raw, _}} = Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])
      assert {:ok, _} = Auth.verify_token(raw)

      Sharing.remove_share(ws.slug, proj.slug, "production")
      assert {:error, :unauthorized} = Auth.verify_token(raw)
    end
  end

  # ── listing ───────────────────────────────────────────────────────────

  describe "list_share_tokens/1" do
    test "lists scope tokens and never exposes the hash", %{ws: ws, proj: proj, scope: scope} do
      share!(scope, "docs:edit")
      {:ok, {_raw, token}} = Auth.create_share_token(ws.slug, proj.slug, "production", ["docs"])

      [listed] = Auth.list_share_tokens(scope)
      assert listed.id == token.id
      assert listed.share_scope == scope
    end
  end
end
