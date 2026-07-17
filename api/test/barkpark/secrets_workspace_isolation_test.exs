defmodule Barkpark.SecretsWorkspaceIsolationTest do
  @moduledoc """
  Cross-workspace isolation proof for the run-secrets store (connectors W21,
  charter D191–D195). RED-FIRST: the core leak test in the first describe was
  run against the UNMODIFIED flat-global store (name-PK, no workspace_id) and
  failed for the store-leak reason — ws-B revealed ws-A's secret — before the
  two-tier schema landed. A green here therefore certifies the WALL, not the
  test.

  Tier law under test (D193, studio_chat `scope_sessions/2` precedent):

    * `:global` (default)      → WHERE workspace_id IS NULL — an explicit arm,
                                 never all-rows; scoped rows are invisible.
    * workspace_id (binary)    → WHERE workspace_id = ^ws — NULL-owner globals
                                 are invisible (no OR-is_nil carve-out: instance
                                 creds must never leak into a tenant scope).
    * anything else (nil)      → fail-closed: zero rows / :not_found / [] /
                                 write refused.

  Workspaces are REAL rows via `Barkpark.TenancyFixtures.create_workspace!/0`
  — `secrets.workspace_id` carries an FK to `workspaces` (D192), so bare
  `Ecto.UUID.generate()` ids would be rejected at insert.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0]

  alias Barkpark.Secrets
  alias Barkpark.Secrets.{SecretRecord, SecretAudit}

  @name "slack_bot_token"

  describe "cross-workspace wall (the RED-FIRST core leak assertions)" do
    # This test is the one captured RED against unmodified origin/main
    # (flat-global store): reveal with a foreign scope returned {:ok, value}.
    test "ws-B cannot reveal, get, or delete ws-A's secret (own scope stays readable)" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "ws-a-value", actor: "alice", scope: ws_a.id)

      # Own-scope sanity FIRST — a wall that blocks everyone proves nothing.
      assert {:ok, "ws-a-value"} = Secrets.reveal(@name, actor: "alice", scope: ws_a.id)

      # The wall: ws-B sees nothing of ws-A's secret.
      assert {:error, :not_found} = Secrets.reveal(@name, actor: "mallory", scope: ws_b.id)
      assert {:error, :not_found} = Secrets.delete(@name, actor: "mallory", scope: ws_b.id)

      # And ws-A's secret survived the foreign delete attempt.
      assert {:ok, "ws-a-value"} = Secrets.reveal(@name, actor: "alice", scope: ws_a.id)
    end

    test "ws-B's scoped get and list never surface ws-A's secret" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "ws-a-value", scope: ws_a.id)

      assert "ws-a-value" == Secrets.get(@name, ws_a.id)
      assert nil == Secrets.get(@name, ws_b.id)

      assert Enum.any?(Secrets.list(ws_a.id), &(&1.name == @name))
      refute Enum.any?(Secrets.list(ws_b.id), &(&1.name == @name))
    end
  end

  describe "global tier vs workspace tier (no cross-tier fallback)" do
    test "a NULL-owner global secret is invisible to every workspace scope" do
      ws_a = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "instance-global-value", actor: "root")

      # Global tier reads it (existing behavior, byte-identical default).
      assert "instance-global-value" == Secrets.get(@name)
      assert {:ok, "instance-global-value"} = Secrets.reveal(@name)

      # No workspace scope may see the instance credential (D35-class leak).
      assert nil == Secrets.get(@name, ws_a.id)
      assert {:error, :not_found} = Secrets.reveal(@name, scope: ws_a.id)
      assert {:error, :not_found} = Secrets.delete(@name, scope: ws_a.id)
      refute Enum.any?(Secrets.list(ws_a.id), &(&1.name == @name))
    end

    test "a workspace-scoped secret is invisible to the :global tier" do
      ws_a = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "tenant-value", scope: ws_a.id)

      # No tenant shadowing of instance reads (ingest_token stays global-pinned).
      assert nil == Secrets.get(@name)
      assert {:error, :not_found} = Secrets.reveal(@name)
      assert {:error, :not_found} = Secrets.delete(@name)
      refute Enum.any?(Secrets.list(), &(&1.name == @name))
    end

    test "ingest_token/0 stays global-pinned even when a workspace shadows the name" do
      ws_a = create_workspace!()

      assert {:ok, _} = Secrets.put("ingest_token", "tenant-shadow", scope: ws_a.id)
      # No global DB row -> falls back to config (config/test.exs fixture).
      assert "barkpark-test-ingest-token" == Secrets.ingest_token()

      assert {:ok, _} = Secrets.put("ingest_token", "rotated-global")
      assert "rotated-global" == Secrets.ingest_token()
    end
  end

  describe "fail-closed on an invalid scope (nil is never a tier)" do
    test "nil scope reads zero rows and refuses writes" do
      ws_a = create_workspace!()
      assert {:ok, _} = Secrets.put(@name, "ws-a-value", scope: ws_a.id)
      assert {:ok, _} = Secrets.put("global_" <> @name, "global-value")

      assert nil == Secrets.get(@name, nil)
      assert [] == Secrets.list(nil)
      assert {:error, :not_found} = Secrets.reveal(@name, scope: nil)
      assert {:error, :not_found} = Secrets.delete(@name, scope: nil)
      assert {:error, :invalid_scope} = Secrets.put(@name, "boom", scope: nil)

      # Nothing landed in either tier from the refused write.
      assert "ws-a-value" == Secrets.get(@name, ws_a.id)
      assert nil == Secrets.get(@name)
    end
  end

  describe "two-tier uniqueness (D191 partial indexes, D194 changeset law)" do
    test "the same name coexists in ws-A, ws-B, and the global tier" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "value-a", scope: ws_a.id)
      assert {:ok, _} = Secrets.put(@name, "value-b", scope: ws_b.id)
      assert {:ok, _} = Secrets.put(@name, "value-global")

      assert "value-a" == Secrets.get(@name, ws_a.id)
      assert "value-b" == Secrets.get(@name, ws_b.id)
      assert "value-global" == Secrets.get(@name)

      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM secrets WHERE name = $1", [@name])

      assert count == 3
    end

    test "put rotates within a tier instead of duplicating (idempotent upsert)" do
      ws_a = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "v1", scope: ws_a.id)
      assert {:ok, _} = Secrets.put(@name, "v2", scope: ws_a.id)
      assert "v2" == Secrets.get(@name, ws_a.id)

      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM secrets WHERE name = $1", [@name])

      assert count == 1
    end

    test "a same-tier duplicate INSERT returns {:error, changeset}, never a raise" do
      ws_a = create_workspace!()
      now = DateTime.utc_now()

      # Workspace tier dup.
      assert {:ok, _} = Secrets.put(@name, "v", scope: ws_a.id)

      assert {:error, %Ecto.Changeset{} = cs} =
               %SecretRecord{}
               |> SecretRecord.changeset(%{
                 name: @name,
                 value: "dup",
                 updated_at: now,
                 workspace_id: ws_a.id
               })
               |> Repo.insert()

      assert %{name: [_ | _]} = errors_on(cs)

      # Global tier dup.
      assert {:ok, _} = Secrets.put("global_" <> @name, "v")

      assert {:error, %Ecto.Changeset{} = cs2} =
               %SecretRecord{}
               |> SecretRecord.changeset(%{
                 name: "global_" <> @name,
                 value: "dup",
                 updated_at: now
               })
               |> Repo.insert()

      assert %{name: [_ | _]} = errors_on(cs2)
    end
  end

  describe "audit workspace dimension (D195)" do
    test "audit rows stamp the acting workspace_id; global actions stamp NULL" do
      ws_a = create_workspace!()

      assert {:ok, _} = Secrets.put(@name, "v", actor: "alice", scope: ws_a.id)
      assert {:ok, "v"} = Secrets.reveal(@name, actor: "alice", scope: ws_a.id)
      assert :ok = Secrets.delete(@name, actor: "alice", scope: ws_a.id)

      scoped_rows =
        Repo.all(
          from(a in SecretAudit, where: a.name == ^@name, select: {a.action, a.workspace_id})
        )

      assert {"set", ws_a.id} in scoped_rows
      assert {"reveal", ws_a.id} in scoped_rows
      assert {"delete", ws_a.id} in scoped_rows

      global_name = "global_" <> @name
      assert {:ok, _} = Secrets.put(global_name, "v", actor: "root")

      assert [{"set", nil}] ==
               Repo.all(
                 from(a in SecretAudit,
                   where: a.name == ^global_name,
                   select: {a.action, a.workspace_id}
                 )
               )
    end
  end
end
