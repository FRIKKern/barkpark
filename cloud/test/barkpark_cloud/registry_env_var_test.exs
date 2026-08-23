defmodule BarkparkCloud.RegistryEnvVarTest do
  @moduledoc """
  Drives the shared/team secrets context surface added in `shared-secrets-env`:

      Registry.put_env_var/2
      Registry.list_env_vars/1,2
      Registry.delete_env_var/2
      Registry.resolved_env_for_barkpark/1

  Covers round-trip encryption (through `Vault.decrypt/1` directly — there is no
  per-row reveal function and no route that returns a value), per-scope partial-
  unique integrity (the NULL≠NULL trick), the scope/barkpark_id discriminator,
  write-once refusal ON THE WRITE PATH (the only path a caller can reach it from),
  most-specific-wins resolution, cross-team isolation, the fail-open-on-bad-row
  resolve, and the FK cascade.
  """
  use BarkparkCloud.DataCase, async: true
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.EnvVar
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  describe "TOCTOU net: assoc_constraint(:barkpark) catches a write against a deleted box" do
    test "insert of a barkpark-scoped env var pointing at a DELETED barkpark → {:error, changeset}" do
      # put_env_var's ownership gate re-reads the barkpark before writing, so the
      # only way the FK target vanishes is the narrow check-to-write TOCTOU window
      # (a concurrent delete_barkpark landing between the gate and Repo.insert).
      # This exercises the net that closes that window DIRECTLY — no concurrency
      # needed: build the exact changeset put_env_var would, against an id whose
      # row no longer exists, and prove assoc_constraint(:barkpark) turns it into a
      # changeset error rather than a raw FK 500. Fail closed: the write never lands.
      team = team_fixture()
      bp = barkpark_fixture(team)
      deleted_id = bp.id
      {:ok, _} = Registry.delete_barkpark(bp)

      assert {:error, %Ecto.Changeset{} = cs} =
               %EnvVar{}
               |> EnvVar.changeset(%{
                 team_id: team.id,
                 key: "RACE_KEY",
                 scope: "barkpark",
                 barkpark_id: deleted_id,
                 value_encrypted: "ciphertext"
               })
               |> Repo.insert()

      # The failure is specifically the barkpark FK net, not something else.
      assert %{barkpark: [_ | _]} = errors_on(cs)

      # Nothing persisted for that dangling id.
      assert Repo.all(from e in EnvVar, where: e.barkpark_id == ^deleted_id) == []
    end
  end

  describe "put_env_var/2" do
    test "round-trips: ciphertext at rest, plaintext under the vault key" do
      team = team_fixture()

      assert {:ok, %EnvVar{} = ev} =
               Registry.put_env_var(team, %{key: "API_KEY", value: "s3cr3t", scope: "team"})

      assert ev.team_id == team.id
      assert ev.scope == "team"
      assert is_nil(ev.barkpark_id)
      # Stored value is ciphertext, never the plaintext.
      refute ev.value_encrypted == "s3cr3t"
      # Decrypt through the Vault directly: the context has no per-row reveal
      # function, and no route hands a value back.
      assert {:ok, "s3cr3t"} = Vault.decrypt(ev.value_encrypted)
    end

    test "upsert: same key+scope twice updates in place (one row)" do
      team = team_fixture()

      {:ok, _} = Registry.put_env_var(team, %{key: "FOO", value: "one", scope: "team"})
      {:ok, ev2} = Registry.put_env_var(team, %{key: "FOO", value: "two", scope: "team"})

      assert {:ok, "two"} = Vault.decrypt(ev2.value_encrypted)
      assert length(Registry.list_env_vars(team)) == 1
    end

    test "honours an explicit is_secret: false (not confused with absent)" do
      team = team_fixture()

      assert {:ok, ev} =
               Registry.put_env_var(team, %{key: "PUBLIC", value: "v", is_secret: false})

      assert ev.is_secret == false
    end

    test "accepts string-keyed attrs (the router shape)" do
      team = team_fixture()

      assert {:ok, ev} =
               Registry.put_env_var(team, %{
                 "key" => "FROM_HTTP",
                 "value" => "v",
                 "scope" => "team"
               })

      assert ev.key == "FROM_HTTP"
      assert {:ok, "v"} = Vault.decrypt(ev.value_encrypted)
    end
  end

  describe "partial-unique integrity" do
    test "two team-scoped vars same key+team → second is a uniqueness error" do
      team = team_fixture()
      {:ok, _} = Registry.put_env_var(team, %{key: "DUP", value: "a", scope: "team"})

      # Force a fresh insert (not the upsert path) by writing the row directly.
      assert {:error, changeset} =
               %EnvVar{}
               |> EnvVar.changeset(%{
                 team_id: team.id,
                 key: "DUP",
                 scope: "team",
                 value_encrypted: "x"
               })
               |> Repo.insert()

      assert "is already taken by a team-scoped var" in errors_on(changeset).key
    end

    test "same key under team AND barkpark scope both succeed (NULL≠NULL)" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:ok, _} = Registry.put_env_var(team, %{key: "SHARED", value: "team", scope: "team"})

      assert {:ok, _} =
               Registry.put_env_var(team, %{
                 key: "SHARED",
                 value: "instance",
                 scope: "barkpark",
                 barkpark_id: bp.id
               })

      assert length(Registry.list_env_vars(team)) == 2
    end
  end

  describe "scope shape discriminator" do
    test "scope: barkpark without barkpark_id → changeset error" do
      team = team_fixture()

      assert {:error, changeset} =
               Registry.put_env_var(team, %{key: "X", value: "v", scope: "barkpark"})

      assert "is required for a barkpark-scoped var" in errors_on(changeset).barkpark_id
    end

    test "scope: team with a barkpark_id → changeset error" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:error, changeset} =
               Registry.put_env_var(team, %{
                 key: "X",
                 value: "v",
                 scope: "team",
                 barkpark_id: bp.id
               })

      assert "must be empty for a team-scoped var" in errors_on(changeset).barkpark_id
    end

    test "rejects a malformed env var name" do
      team = team_fixture()

      assert {:error, changeset} =
               Registry.put_env_var(team, %{key: "1BAD", value: "v", scope: "team"})

      assert Map.has_key?(errors_on(changeset), :key)
    end
  end

  # cch-w22-s3 — the comment cap is a COLUMN fact, not a taste. `comment` is
  # `add :comment, :string` = varchar(255). The changeset validated it at 1000,
  # so 256 characters passed validation and then raised Postgrex 22001
  # (string_data_right_truncation) inside `Repo.insert_or_update` — and because
  # nothing in this app installs a `Plug.ErrorHandler`, the raise reached the
  # person as a bare 500 behind "Check the values and try again."
  #
  # THE TEST HAS TO BE ABLE TO LOSE: it pins BOTH sides of the boundary. 255 must
  # still WRITE (a cap that merely rejects everything long would also pass a
  # one-sided test), and 256 must come back as a changeset error and never as a
  # raise — which is why the 256 case goes through the real `put_env_var/2` write
  # path rather than stopping at `EnvVar.changeset/2`.
  describe "comment length is capped at the column (255), not at 1000" do
    test "255 characters is accepted and stored verbatim" do
      team = team_fixture()
      comment = String.duplicate("x", 255)

      assert {:ok, ev} =
               Registry.put_env_var(team, %{
                 key: "COMMENT_AT_CAP",
                 value: "v",
                 scope: "team",
                 comment: comment
               })

      assert String.length(ev.comment) == 255
      assert Repo.get!(EnvVar, ev.id).comment == comment
    end

    test "256 characters is a changeset error, not a Postgrex 22001 raise" do
      team = team_fixture()

      assert {:error, changeset} =
               Registry.put_env_var(team, %{
                 key: "COMMENT_OVER_CAP",
                 value: "v",
                 scope: "team",
                 comment: String.duplicate("x", 256)
               })

      assert Enum.any?(errors_on(changeset).comment, &String.contains?(&1, "255"))

      # and nothing was written — the 422 is honest about the row not existing
      assert Repo.aggregate(
               from(e in EnvVar, where: e.team_id == ^team.id and e.key == "COMMENT_OVER_CAP"),
               :count
             ) == 0
    end
  end

  describe "write-once" do
    test "a write to an is_shown_once var is refused" do
      team = team_fixture()

      {:ok, ev} =
        Registry.put_env_var(team, %{key: "ONCE", value: "v1", is_shown_once: true})

      assert {:error, :write_once} =
               Registry.put_env_var(team, %{key: "ONCE", value: "v2"})

      # The row is untouched: the original ciphertext still decrypts to v1. The
      # write path is the ONLY path write-once can be exercised from — there is no
      # reveal function and no route that returns a value.
      assert {:ok, "v1"} = Vault.decrypt(Repo.get!(EnvVar, ev.id).value_encrypted)
    end
  end

  describe "resolved_env_for_barkpark/1" do
    test "most-specific-wins: instance value shadows team value" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, _} = Registry.put_env_var(team, %{key: "FOO", value: "team", scope: "team"})
      {:ok, _} = Registry.put_env_var(team, %{key: "BAR", value: "teamonly", scope: "team"})

      {:ok, _} =
        Registry.put_env_var(team, %{
          key: "FOO",
          value: "instance",
          scope: "barkpark",
          barkpark_id: bp.id
        })

      resolved = Registry.resolved_env_for_barkpark(bp)
      assert resolved["FOO"] == "instance"
      assert resolved["BAR"] == "teamonly"
    end

    test "an instance override for ANOTHER barkpark is absent" do
      team = team_fixture()
      bp1 = barkpark_fixture(team)
      bp2 = barkpark_fixture(team)

      {:ok, _} =
        Registry.put_env_var(team, %{
          key: "ONLY_BP2",
          value: "v",
          scope: "barkpark",
          barkpark_id: bp2.id
        })

      assert Registry.resolved_env_for_barkpark(bp1) == %{}
    end

    test "skips an undecryptable row, returns the rest, no raise" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, good} = Registry.put_env_var(team, %{key: "GOOD", value: "ok", scope: "team"})
      {:ok, bad} = Registry.put_env_var(team, %{key: "BAD", value: "x", scope: "team"})

      # Corrupt the ciphertext so Vault.decrypt/1 fails closed.
      Repo.update_all(
        from(e in EnvVar, where: e.id == ^bad.id),
        set: [value_encrypted: "not-valid-ciphertext"]
      )

      resolved = Registry.resolved_env_for_barkpark(bp)
      assert resolved == %{"GOOD" => "ok"}
      assert good.id
    end
  end

  describe "tenancy isolation" do
    test "another team's vars never appear in this team's reads or resolution" do
      team_a = team_fixture()
      team_b = team_fixture()
      bp_a = barkpark_fixture(team_a)

      {:ok, _} = Registry.put_env_var(team_b, %{key: "SECRET_B", value: "b", scope: "team"})

      assert Registry.list_env_vars(team_a) == []
      assert Registry.resolved_env_for_barkpark(bp_a) == %{}
    end

    test "delete_env_var is team-scoped: another team's id → not_found" do
      team_a = team_fixture()
      team_b = team_fixture()
      {:ok, ev_b} = Registry.put_env_var(team_b, %{key: "B", value: "v", scope: "team"})

      assert {:error, :not_found} = Registry.delete_env_var(team_a, ev_b.id)
      # The row survives.
      assert Repo.get(EnvVar, ev_b.id)
    end

    test "delete_env_var on an invalid (non-UUID) id → not_found" do
      team = team_fixture()
      assert {:error, :not_found} = Registry.delete_env_var(team, "not-a-uuid")
    end
  end

  describe "barkpark ownership gate (security)" do
    test "put_env_var rejects a barkpark_id owned by ANOTHER team, writes nothing" do
      team_a = team_fixture()
      team_b = team_fixture()
      bp_b = barkpark_fixture(team_b)

      # Team A supplies Team B's instance id — the FK would accept it (the row
      # exists), so the context ownership check is the ONLY thing that stops the
      # cross-tenant write. It MUST fail closed.
      assert {:error, :barkpark_not_in_team} =
               Registry.put_env_var(team_a, %{
                 key: "STOLEN",
                 value: "v",
                 scope: "barkpark",
                 barkpark_id: bp_b.id
               })

      # No row landed for A; B's instance never sees A's secret.
      assert Registry.list_env_vars(team_a) == []
      assert Registry.resolved_env_for_barkpark(bp_b) == %{}
    end

    test "put_env_var accepts a barkpark_id the team DOES own" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:ok, ev} =
               Registry.put_env_var(team, %{
                 key: "MINE",
                 value: "v",
                 scope: "barkpark",
                 barkpark_id: bp.id
               })

      assert ev.barkpark_id == bp.id
    end

    test "put_env_var rejects a non-existent barkpark_id (fail closed)" do
      team = team_fixture()

      assert {:error, :barkpark_not_in_team} =
               Registry.put_env_var(team, %{
                 key: "GHOST",
                 value: "v",
                 scope: "barkpark",
                 barkpark_id: Ecto.UUID.generate()
               })
    end
  end

  describe "FK cascade" do
    test "deleting a team drops its env vars" do
      team = team_fixture()
      {:ok, ev} = Registry.put_env_var(team, %{key: "K", value: "v", scope: "team"})

      Repo.delete!(team)
      refute Repo.get(EnvVar, ev.id)
    end

    test "deleting a barkpark drops its instance vars but keeps team-scoped ones" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, team_var} = Registry.put_env_var(team, %{key: "TEAMVAR", value: "v", scope: "team"})

      {:ok, inst_var} =
        Registry.put_env_var(team, %{
          key: "INSTVAR",
          value: "v",
          scope: "barkpark",
          barkpark_id: bp.id
        })

      Repo.delete!(bp)

      refute Repo.get(EnvVar, inst_var.id)
      assert Repo.get(EnvVar, team_var.id)
    end
  end
end
