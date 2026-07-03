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
      %{key: key, raw: raw} = mint!()
      {:ok, _} = Keys.revoke(key.id)
      assert {:error, :unauthorized} = Keys.verify(raw)
    end

    test "an expired key is unauthorized" do
      %{key: key, raw: raw} = mint!()
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      key |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()
      assert {:error, :unauthorized} = Keys.verify(raw)
    end

    test "a paused key is :paused — a distinguishable, reversible mute" do
      %{key: key, raw: raw} = mint!()
      {:ok, _} = Keys.pause(key.id)
      assert {:error, :paused} = Keys.verify(raw)

      {:ok, _} = Keys.unpause(key.id)
      assert {:ok, _} = Keys.verify(raw)
    end

    test "a revoked+paused key is unauthorized (revoked wins — no oracle)" do
      %{key: key, raw: raw} = mint!()
      {:ok, _} = Keys.pause(key.id)
      {:ok, _} = Keys.revoke(key.id)
      assert {:error, :unauthorized} = Keys.verify(raw)
    end

    test "never resolves a normal kind==\"api\" token" do
      ws = create_workspace!()
      raw = "bppat_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      {:ok, _token} = Auth.create_token(raw, "an api token", "production", ["read"], ws.id)
      assert {:error, :unauthorized} = Keys.verify(raw)
    end
  end

  describe "rotate/1" do
    test "issues a new secret on the SAME row and kills the old instantly" do
      %{key: key, raw: old_raw} = mint!()
      assert {:ok, %{key: rotated, raw: new_raw}} = Keys.rotate(key.id)

      assert rotated.id == key.id
      assert rotated.name == key.name
      refute new_raw == old_raw
      assert {:error, :unauthorized} = Keys.verify(old_raw)
      assert {:ok, resolved} = Keys.verify(new_raw)
      assert resolved.id == key.id
    end

    test "not_found for an unknown or malformed id" do
      assert {:error, :not_found} = Keys.rotate(Ecto.UUID.generate())
      assert {:error, :not_found} = Keys.rotate("not-a-uuid")
    end
  end

  describe "pause/unpause/revoke/1" do
    test "not_found for an unknown id" do
      assert {:error, :not_found} = Keys.pause(Ecto.UUID.generate())
      assert {:error, :not_found} = Keys.unpause(Ecto.UUID.generate())
      assert {:error, :not_found} = Keys.revoke(Ecto.UUID.generate())
    end

    test "will not touch a normal api token (kind-fenced)" do
      ws = create_workspace!()
      raw = "bppat_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      {:ok, token} = Auth.create_token(raw, "an api token", "production", ["read"], ws.id)
      assert {:error, :not_found} = Keys.revoke(token.id)
      assert {:error, :not_found} = Keys.pause(token.id)
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
  end

  test "Auth.verify_token/1 never returns a ticket-kind row (fail-closed choke point)" do
    %{raw: raw} = mint!()
    assert {:error, :unauthorized} = Auth.verify_token(raw)
  end
end
