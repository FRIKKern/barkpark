defmodule Barkpark.Plugins.Tickets.KeysTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Tickets.Keys

  import Barkpark.TenancyFixtures

  defp mint!(attrs \\ %{}) do
    ws = create_workspace!()
    {:ok, minted} = Keys.mint(Map.merge(%{name: "Gyldendal — Kari", workspace_id: ws.id}, attrs))
    Map.put(minted, :workspace, ws)
  end

  describe "mint/1" do
    test "returns a bptk_-prefixed raw key shown once, storing only the hash" do
      %{key: key, raw: raw} = mint!()

      assert String.starts_with?(raw, "bptk_")
      assert key.kind == "ticket"
      assert key.name == "Gyldendal — Kari"
      # The stored hash is the SHA-256 of the raw — the raw itself is never
      # persisted, so it is unrecoverable after this response.
      assert key.token_hash == ApiToken.hash_token(raw)
      refute key.token_hash == raw
    end

    test "binds the key to the workspace and marks it inert (opaque permission)" do
      %{key: key, workspace: ws} = mint!()

      assert key.workspace_id == ws.id
      # No global read/write/admin tier — a ticket key can drive nothing but the
      # ticket surface even if the kind-fence were bypassed.
      refute Auth.has_permission?(key, "read")
      refute Auth.has_permission?(key, "write")
      refute Auth.has_permission?(key, "admin")
    end

    test "each mint yields a distinct secret" do
      %{raw: a} = mint!()
      %{raw: b} = mint!()
      refute a == b
    end

    test "rejects a missing or blank name" do
      ws = create_workspace!()
      assert {:error, :invalid_name} = Keys.mint(%{workspace_id: ws.id})
      assert {:error, :invalid_name} = Keys.mint(%{name: "   ", workspace_id: ws.id})
      assert {:error, :invalid_name} = Keys.mint(%{name: nil, workspace_id: ws.id})
    end

    test "rejects an over-long name cleanly (422 material, never a varchar-255 500)" do
      ws = create_workspace!()

      assert {:error, :name_too_long} =
               Keys.mint(%{name: String.duplicate("k", 201), workspace_id: ws.id})

      assert {:ok, _} = Keys.mint(%{name: String.duplicate("k", 200), workspace_id: ws.id})
    end

    test "accepts string keys too (controller passes string params)" do
      ws = create_workspace!()
      assert {:ok, %{key: key}} = Keys.mint(%{"name" => "Kari", "workspace_id" => ws.id})
      assert key.name == "Kari"
    end
  end

  describe "verify/1" do
    test "resolves a live key to its row" do
      %{key: key, raw: raw} = mint!()
      assert {:ok, resolved} = Keys.verify(raw)
      assert resolved.id == key.id
    end

    test "an unknown key is unauthorized" do
      assert {:error, :unauthorized} = Keys.verify("bptk_nope")
      assert {:error, :unauthorized} = Keys.verify("garbage")
      assert {:error, :unauthorized} = Keys.verify(nil)
    end

    test "a revoked key is unauthorized (indistinguishable from missing)" do
      %{key: key, raw: raw, workspace: ws} = mint!()
      {:ok, _} = Keys.revoke(key.id, ws.id)
      assert {:error, :unauthorized} = Keys.verify(raw)
    end

    test "an expired key is unauthorized" do
      %{key: key, raw: raw} = mint!()
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      key |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()
      assert {:error, :unauthorized} = Keys.verify(raw)
    end

    test "a paused key is :paused — a distinguishable, reversible mute" do
      %{key: key, raw: raw, workspace: ws} = mint!()
      {:ok, _} = Keys.pause(key.id, ws.id)
      assert {:error, :paused} = Keys.verify(raw)

      {:ok, _} = Keys.unpause(key.id, ws.id)
      assert {:ok, _} = Keys.verify(raw)
    end

    test "a revoked+paused key is unauthorized (revoked wins — no oracle)" do
      %{key: key, raw: raw, workspace: ws} = mint!()
      {:ok, _} = Keys.pause(key.id, ws.id)
      {:ok, _} = Keys.revoke(key.id, ws.id)
      assert {:error, :unauthorized} = Keys.verify(raw)
    end

    test "never resolves a normal kind==\"api\" token" do
      ws = create_workspace!()
      raw = "bppat_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      {:ok, _token} = Auth.create_token(raw, "an api token", "production", ["read"], ws.id)
      assert {:error, :unauthorized} = Keys.verify(raw)
    end
  end

  describe "rotate/2" do
    test "issues a new secret on the SAME row and kills the old instantly" do
      %{key: key, raw: old_raw, workspace: ws} = mint!()
      assert {:ok, %{key: rotated, raw: new_raw}} = Keys.rotate(key.id, ws.id)

      assert rotated.id == key.id
      assert rotated.name == key.name
      refute new_raw == old_raw
      assert {:error, :unauthorized} = Keys.verify(old_raw)
      assert {:ok, resolved} = Keys.verify(new_raw)
      assert resolved.id == key.id
    end

    test "not_found for an unknown or malformed id" do
      ws = create_workspace!()
      assert {:error, :not_found} = Keys.rotate(Ecto.UUID.generate(), ws.id)
      assert {:error, :not_found} = Keys.rotate("not-a-uuid", ws.id)
    end
  end

  describe "pause/unpause/revoke/2" do
    test "not_found for an unknown id" do
      ws = create_workspace!()
      assert {:error, :not_found} = Keys.pause(Ecto.UUID.generate(), ws.id)
      assert {:error, :not_found} = Keys.unpause(Ecto.UUID.generate(), ws.id)
      assert {:error, :not_found} = Keys.revoke(Ecto.UUID.generate(), ws.id)
    end

    test "will not touch a normal api token (kind-fenced)" do
      ws = create_workspace!()
      raw = "bppat_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      {:ok, token} = Auth.create_token(raw, "an api token", "production", ["read"], ws.id)
      assert {:error, :not_found} = Keys.revoke(token.id, ws.id)
      assert {:error, :not_found} = Keys.pause(token.id, ws.id)
    end
  end

  describe "workspace scope (cross-tenant IDOR)" do
    test "another workspace's key is not_found for every by-id mutation, state unchanged" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      {:ok, %{key: b_key, raw: b_raw}} = Keys.mint(%{name: "B-owned", workspace_id: ws_b.id})

      # ws A (a different tenant's admin) cannot reach ws B's key through ANY
      # by-id mutation — the workspace fence makes it invisible, not merely 403.
      assert {:error, :not_found} = Keys.rotate(b_key.id, ws_a.id)
      assert {:error, :not_found} = Keys.pause(b_key.id, ws_a.id)
      assert {:error, :not_found} = Keys.unpause(b_key.id, ws_a.id)
      assert {:error, :not_found} = Keys.revoke(b_key.id, ws_a.id)

      # The key is untouched: still live, still the same secret, never paused or
      # revoked by the cross-tenant attempts.
      reloaded = Repo.get!(ApiToken, b_key.id)
      assert is_nil(reloaded.paused_at)
      assert is_nil(reloaded.revoked_at)
      assert {:ok, _} = Keys.verify(b_raw)

      # FAIL-CLOSED: a nil workspace scope matches only un-bound keys, so it
      # cannot reach a bound key either (contrast list/1's nil → all keys).
      assert {:error, :not_found} = Keys.revoke(b_key.id, nil)

      # ws B — the real owner — still operates its own key.
      assert {:ok, _} = Keys.pause(b_key.id, ws_b.id)
    end
  end

  describe "list/1" do
    test "returns the workspace's ticket keys, newest first, no api tokens" do
      ws = create_workspace!()
      {:ok, %{key: k1}} = Keys.mint(%{name: "One", workspace_id: ws.id})
      {:ok, %{key: k2}} = Keys.mint(%{name: "Two", workspace_id: ws.id})

      # A normal api token in the same workspace must NOT appear.
      raw = "bppat_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      {:ok, _} = Auth.create_token(raw, "api", "production", ["read"], ws.id)

      ids = ws |> Keys.list() |> Enum.map(& &1.id)
      assert k1.id in ids
      assert k2.id in ids
      assert length(ids) == 2
    end

    test "filters by workspace" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      {:ok, %{key: a}} = Keys.mint(%{name: "A", workspace_id: ws_a.id})
      {:ok, %{key: _b}} = Keys.mint(%{name: "B", workspace_id: ws_b.id})

      ids = ws_a.id |> Keys.list() |> Enum.map(& &1.id)
      assert ids == [a.id]
    end

    # THE LIST DOOR. `get_ticket_key/2`'s fence (`scope_workspace/2`) is
    # fail-CLOSED on nil — a nil-scoped caller sees only the un-bound keys — and
    # its own comment names this exact widening as the fail-OPEN it prevents.
    # `list/1` used to skip the WHERE entirely on nil, so a caller whose
    # workspace never resolved read EVERY tenant's ticket keys. Both request
    # callers pass a workspace that can be nil: `TicketKeysController.index`
    # (`current_workspace_id/1` → nil when `:current_workspace` is unset) and
    # `InboxLive.fetch_keys` (`socket.assigns[:current_workspace]`, which
    # StudioChrome's `default_scope_fallback/1` leaves nil on an unseeded
    # tenancy).
    test "a nil scope does NOT widen to every tenant's keys (fail-closed, like the by-id fence)" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      {:ok, %{key: a}} = Keys.mint(%{name: "A", workspace_id: ws_a.id})
      {:ok, %{key: b}} = Keys.mint(%{name: "B", workspace_id: ws_b.id})

      ids = nil |> Keys.list() |> Enum.map(& &1.id)

      refute a.id in ids, "a nil scope returned workspace A's ticket keys"
      refute b.id in ids, "a nil scope returned workspace B's ticket keys"
    end

    # The mirror of the fence's OTHER half: nil is not "nothing", it is the
    # un-bound tenant. A key minted with no workspace is exactly what a
    # nil-scoped caller owns — and it is what `get_ticket_key/2` already
    # returns them.
    test "a nil scope still returns the un-bound keys — the tenant nil actually names" do
      ws = create_workspace!()
      {:ok, %{key: bound}} = Keys.mint(%{name: "Bound", workspace_id: ws.id})
      {:ok, %{key: unbound}} = Keys.mint(%{name: "Unbound"})

      ids = nil |> Keys.list() |> Enum.map(& &1.id)

      assert unbound.id in ids
      refute bound.id in ids
    end
  end

  test "Auth.verify_token/1 never returns a ticket-kind row (fail-closed choke point)" do
    %{raw: raw} = mint!()
    assert {:error, :unauthorized} = Auth.verify_token(raw)
  end

  test "the weekly public-read purge never sweeps a ticket key (kind-fenced)" do
    ws = create_workspace!()

    # A ticket key whose operator-chosen name mirrors into `label` and happens
    # to match the purge's LIKE 'public-read-%' pattern…
    {:ok, %{key: key}} = Keys.mint(%{name: "public-read-sneaky", workspace_id: ws.id})

    # …and a REAL rotation token the purge is for.
    {:ok, _raw, doomed} =
      Barkpark.Auth.PublicRead.create_public_read_token("public-read-2026-old")

    cutoff = DateTime.utc_now() |> DateTime.add(60)
    {:ok, n} = Barkpark.Auth.PublicRead.purge_public_read_older_than(cutoff)

    assert n >= 1
    refute Repo.get(ApiToken, doomed.id)
    assert Repo.get(ApiToken, key.id), "the purge deleted a ticket key — an outsider's identity"
  end

  # Same collateral class as the kind-fence above, one tier over. The purge is
  # an instance-wide `delete_all` — it spans every workspace — and the LIKE
  # pattern matches on a caller-chosen LABEL. `TokenController` lets a tenant
  # name its own api-kind token freely, so a token labelled "public-read-…"
  # in ANOTHER workspace was swept by the weekly rotation timer. Fence on the
  # tier the creator actually stamps (`["public-read"]`, the same predicate
  # `Plugs.PublicRead.public_read_token?/1` uses) so only real rotation tokens
  # are in scope.
  test "the weekly public-read purge never sweeps a tenant's own api token that merely shares the label prefix" do
    ws = create_workspace!()

    raw = "bppat_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    {:ok, tenant_token} =
      Auth.create_token(raw, "public-read-my-blog-feed", "production", ["read"], ws.id)

    {:ok, _raw, doomed} =
      Barkpark.Auth.PublicRead.create_public_read_token("public-read-2026-old")

    cutoff = DateTime.utc_now() |> DateTime.add(60)
    {:ok, n} = Barkpark.Auth.PublicRead.purge_public_read_older_than(cutoff)

    assert n >= 1
    refute Repo.get(ApiToken, doomed.id), "the real rotation token survived the purge"

    assert Repo.get(ApiToken, tenant_token.id),
           "the purge deleted another tenant's api token on a label-prefix match alone"
  end
end
