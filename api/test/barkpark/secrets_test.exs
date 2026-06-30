defmodule Barkpark.SecretsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Secrets
  alias Barkpark.Secrets.SecretAudit

  @name "test_secret"

  describe "put/3 + get/1 + reveal/2 round-trip" do
    test "stores and retrieves the original value through encryption" do
      assert {:ok, _rec} = Secrets.put(@name, "supersecretvalue123", actor: "alice")
      assert "supersecretvalue123" == Secrets.get(@name)
      assert {:ok, "supersecretvalue123"} = Secrets.reveal(@name, actor: "alice")
    end

    test "put rotates a previous value" do
      assert {:ok, _} = Secrets.put(@name, "v1", actor: "alice")
      assert {:ok, _} = Secrets.put(@name, "v2", actor: "alice")
      assert "v2" == Secrets.get(@name)
    end

    test "get on a missing secret returns nil (no audit)" do
      assert nil == Secrets.get("never_set")
      assert audit_actions("never_set") == []
    end
  end

  describe "encryption at rest" do
    test "raw column does not contain the plaintext value" do
      marker = "PLAINTEXT_MARKER_DO_NOT_LEAK_3f8a"
      assert {:ok, _} = Secrets.put(@name, marker)

      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT value FROM secrets WHERE name = $1",
          [@name]
        )

      raw_str =
        cond do
          is_binary(raw) -> raw
          is_list(raw) -> IO.iodata_to_binary(raw)
          true -> inspect(raw)
        end

      refute String.contains?(raw_str, marker)
    end
  end

  describe "audit log" do
    test "put writes a set audit row; reveal writes a reveal row; delete a delete row" do
      assert {:ok, _} = Secrets.put(@name, "v", actor: "bob")
      assert {:ok, "v"} = Secrets.reveal(@name, actor: "bob")
      assert :ok = Secrets.delete(@name, actor: "bob")

      actions = audit_actions(@name)
      assert "set" in actions
      assert "reveal" in actions
      assert "delete" in actions
    end

    test "get does NOT write an audit row" do
      assert {:ok, _} = Secrets.put(@name, "v", actor: "carol")
      _ = Secrets.get(@name)
      # only the "set" from put — no read/reveal row
      assert audit_actions(@name) == ["set"]
    end

    test "reveal on missing secret returns :not_found and writes no audit row" do
      assert {:error, :not_found} = Secrets.reveal("never_existed")
      assert audit_actions("never_existed") == []
    end
  end

  describe "list/0 (masked)" do
    test "returns names with masked values, never plaintext" do
      assert {:ok, _} = Secrets.put(@name, "secret-value-wxyz")
      rows = Secrets.list()
      row = Enum.find(rows, &(&1.name == @name))
      assert row.value == "********wxyz"
    end
  end

  describe "delete/2" do
    test "after delete, get returns nil" do
      assert {:ok, _} = Secrets.put(@name, "v")
      assert :ok = Secrets.delete(@name)
      assert nil == Secrets.get(@name)
    end

    test "delete on missing returns :not_found" do
      assert {:error, :not_found} = Secrets.delete("does_not_exist")
    end
  end

  describe "ingest_token/0" do
    test "falls back to app config when no DB row exists" do
      assert nil == Secrets.get("ingest_token")
      # config/test.exs sets the fixed test ingest secret.
      assert "barkpark-test-ingest-token" == Secrets.ingest_token()
    end

    test "DB row overrides the env config" do
      assert {:ok, _} = Secrets.put("ingest_token", "rotated-db-secret")
      assert "rotated-db-secret" == Secrets.ingest_token()
    end
  end

  defp audit_actions(name) do
    from(a in SecretAudit, where: a.name == ^name, select: a.action)
    |> Repo.all()
  end
end
