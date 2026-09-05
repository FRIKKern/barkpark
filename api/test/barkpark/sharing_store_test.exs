defmodule Barkpark.SharingStoreTest do
  @moduledoc """
  P4 — the PERSISTENT share registry (`shares` table) and the env+DB merge.

  These exercise the store path: `add_share/1` (validate-then-upsert),
  `remove_share/3`, `list_stored/0` (revalidated reads), and `refresh/0` (the
  `shares_env ++ list_stored` merge that feeds the live `:shares`).

  The whole module is `async: false`: it mutates the process-global
  `:barkpark, :shares` AND `:barkpark, :shares_env` Application env (restored
  on_exit), so it must never race a test that asserts the empty default.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Sharing
  alias Barkpark.Sharing.{Share, StoredShare}
  alias Barkpark.Repo
  alias Barkpark.SharingFixtures

  setup do
    # Snapshot BOTH env keys and the live list; restore them after each test so a
    # stored share written here can never leak into another module's view.
    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)

    # Start every test from a clean, OFF baseline.
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  # ── add_share/1 — validate then persist ─────────────────────────────────

  describe "add_share/1" do
    test "persists a valid entry and refresh makes it live" do
      assert {:ok, %Share{workspace_slug: "gyldendal", surfaces: [:papers, :docs]}} =
               Sharing.add_share("gyldendal/books/production:papers,docs:read")

      # one row landed
      assert [%StoredShare{surfaces: surfaces, access: "read"}] = Repo.all(StoredShare)
      assert Enum.sort(surfaces) == ["docs", "papers"]

      # and add_share already refreshed the live list
      assert Sharing.shared?("gyldendal", "books", "production", :papers)
      assert Sharing.shared?("gyldendal", "books", "production", :docs)
      assert Sharing.access_for("gyldendal", "books", "production") == :read
    end

    test "is an UPSERT — same scope replaces surfaces/access, never duplicates" do
      assert {:ok, _} = Sharing.add_share("gyldendal/books/production:papers:read")
      assert {:ok, _} = Sharing.add_share("gyldendal/books/production:docs,media:edit")

      # still exactly one row for the scope
      assert [%StoredShare{surfaces: surfaces, access: "edit"}] = Repo.all(StoredShare)
      assert Enum.sort(surfaces) == ["docs", "media"]

      # the live list reflects the replacement, not a union
      refute Sharing.shared?("gyldendal", "books", "production", :papers)
      assert Sharing.shared?("gyldendal", "books", "production", :docs)
      assert Sharing.access_for("gyldendal", "books", "production") == :edit
    end

    test "rejects a wildcard scope (no row, no grant)" do
      assert {:error, :invalid} = Sharing.add_share("*/books/production:papers:read")
      assert Repo.all(StoredShare) == []
    end

    test "rejects a multi-entry string (one scope at a time)" do
      assert {:error, :invalid} = Sharing.add_share("a:papers:read;b:docs:read")
      assert Repo.all(StoredShare) == []
    end

    test "rejects an entry whose surfaces are all unknown" do
      assert {:error, :invalid} = Sharing.add_share("gyldendal:wat,nope:read")
      assert Repo.all(StoredShare) == []
    end

    test "rejects a non-binary argument" do
      assert {:error, :invalid} = Sharing.add_share(:not_a_string)
    end
  end

  # ── remove_share/3 ──────────────────────────────────────────────────────

  describe "remove_share/3" do
    test "deletes the scope's row and refresh drops it from the live list" do
      assert {:ok, _} = Sharing.add_share("gyldendal/books/production:papers:read")
      assert Sharing.shared?("gyldendal", "books", "production", :papers)

      assert {:ok, 1} = Sharing.remove_share("gyldendal", "books", "production")

      assert Repo.all(StoredShare) == []
      refute Sharing.shared?("gyldendal", "books", "production", :papers)
    end

    test "removing an absent scope is a no-op returning {:ok, 0}" do
      assert {:ok, 0} = Sharing.remove_share("nobody", "here", "production")
    end

    test "removes only STORED shares — the env baseline survives" do
      Application.put_env(:barkpark, :shares_env, Sharing.parse("env-ws:papers:read"))
      assert {:ok, _} = Sharing.add_share("db-ws/default/production:papers:read")
      Sharing.refresh()

      assert {:ok, 1} = Sharing.remove_share("db-ws", "default", "production")

      # the stored one is gone, the env one remains
      refute Sharing.shared?("db-ws", "default", "production", :papers)
      assert Sharing.shared?("env-ws", "default", "production", :papers)
    end
  end

  # ── list_stored/0 + refresh/0 ──────────────────────────────────────────

  describe "list_stored/0 — revalidated reads" do
    test "drops a stored row whose surfaces are all unknown (defense in depth)" do
      # Bypass add_share to plant a structurally-valid but semantically-bogus row
      # (a stale token a future schema change could leave behind).
      Repo.insert!(%StoredShare{
        workspace_slug: "ws",
        project_slug: "default",
        dataset: "production",
        surfaces: ["wat"],
        access: "read"
      })

      assert Sharing.list_stored() == []
    end
  end

  describe "refresh/0 — env + DB merge" do
    test "live :shares = env baseline ++ stored, both reachable" do
      Application.put_env(:barkpark, :shares_env, Sharing.parse("env-ws:papers:read"))
      Sharing.add_share("db-ws/default/production:docs:read")
      # add_share refreshed already; call again to prove idempotence
      Sharing.refresh()

      assert Sharing.shared?("env-ws", "default", "production", :papers)
      assert Sharing.shared?("db-ws", "default", "production", :docs)
      assert length(Sharing.shares()) == 2
    end

    test "with no env and no rows, refresh yields the OFF default" do
      Sharing.refresh()
      assert Sharing.shares() == []
      refute Sharing.active?()
    end
  end

  # ── arpss-w8: the FIXTURE-WIPE class, pinned in both directions ──────────
  #
  # `refresh/0` = `shares_env() ++ list_stored()`. A fixture that is in neither
  # input does not survive it, and the wipe is SILENT — the suite goes on
  # asserting over an empty registry and passes. These two tests pin the pair:
  # the sanctioned planting survives an unrelated write, and the bare `put_env`
  # planting demonstrably does not.

  describe "fixture survival across an unrelated refresh (arpss-w8)" do
    test "a share planted through plant_shares!/1 survives an unrelated add_share" do
      SharingFixtures.plant_shares!("victim-ws/victim-proj/production:docs:edit")
      assert Sharing.shared?("victim-ws", "victim-proj", "production", :docs)
      assert Sharing.access_for("victim-ws", "victim-proj", "production") == :edit

      # An UNRELATED scope is shared — the natural way to build a second-tenant
      # fixture. add_share/1 fires refresh/0, which recomputes the whole list.
      assert {:ok, _} = Sharing.add_share("other-ws/other-proj/production:papers:read")

      # The planted fixture is STILL live: it is a StoredShare row, so
      # list_stored/0 rebuilt it.
      assert Sharing.shared?("victim-ws", "victim-proj", "production", :docs),
             "the planted fixture was erased by an unrelated add_share — planting must go through Sharing.add_share/1, not a bare Application.put_env(:barkpark, :shares, …)"

      assert Sharing.access_for("victim-ws", "victim-proj", "production") == :edit
      assert Sharing.shared?("other-ws", "other-proj", "production", :papers)

      # And an explicit second refresh changes nothing — idempotent.
      Sharing.refresh()
      assert Sharing.shared?("victim-ws", "victim-proj", "production", :docs)
    end

    test "a bare put_env fixture IS erased by an unrelated add_share — the hazard itself" do
      SharingFixtures.snapshot_shares!()

      Application.put_env(
        :barkpark,
        :shares,
        Sharing.parse("victim-ws/victim-proj/production:docs:edit")
      )

      assert Sharing.shared?("victim-ws", "victim-proj", "production", :docs),
             "non-vacuous: the bare put_env fixture starts LIVE"

      assert {:ok, _} = Sharing.add_share("other-ws/other-proj/production:papers:read")

      refute Sharing.shared?("victim-ws", "victim-proj", "production", :docs)
      assert Sharing.shares() |> Enum.map(& &1.workspace_slug) == ["other-ws"]
    end

    test "plant_shares!/1 REFUSES a comma-joined multi-scope string (parse splits on \";\")" do
      assert_raise ArgumentError, fn ->
        SharingFixtures.plant_shares!("ws-a:papers:read,ws-b:papers:read")
      end
    end
  end
end
