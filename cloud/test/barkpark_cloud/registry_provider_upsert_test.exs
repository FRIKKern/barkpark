defmodule BarkparkCloud.RegistryProviderUpsertTest do
  @moduledoc """
  Charter GR44 — a Team has AT MOST ONE provider per kind.

  `connect_provider/4` used to be a plain `Repo.insert` over a table whose only
  index was a NON-unique one on `team_id`, so "reconnect your Hetzner account"
  appended a row and the three newest-wins read paths
  (`resolved_azure_credentials_for_barkpark`, `resolve_cloudflare_credential`,
  `provider_of_kind/2` via `list_providers/1`) papered over it. This suite pins
  BOTH halves of the fix:

    * the write — reconnect ROTATES the one row (and returns the row Postgres
      actually kept), and the unique index refuses a duplicate from any other
      writer;
    * the migration — its dedup DELETE really does collapse a pre-existing
      duplicate pair to the NEWEST row.

  ## The design trap this suite had to dodge

  Once the upsert shipped, `connect_provider/4` became STRUCTURALLY UNABLE to
  create a duplicate, so the dedup half cannot be seeded through the public API
  — a test that tried would silently prove nothing (it would assert `1 == 1`
  about a pair that never existed). The duplicate is therefore seeded with
  `Repo.insert_all` after DROPPING the unique index INSIDE the sandboxed test
  transaction: Postgres DDL is transactional, so the index is back the moment
  the test rolls back and no other test can see the gap.

  And the DELETE is not retyped here — it is READ OUT of the migration file, so
  editing the migration re-runs this proof against the new bytes instead of
  leaving a stale copy asserting green.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Provider

  @migration Path.expand(
               "../../priv/repo/migrations/20260719203000_unique_provider_per_team_kind.exs",
               __DIR__
             )

  @index_name "providers_team_id_kind_index"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp token_of(%Provider{} = p) do
    {:ok, plaintext} = Registry.reveal_provider_token(p)
    plaintext
  end

  # The migration's dedup statement, verbatim — parsed out of the file so this
  # test can never drift from the SQL that actually runs against production.
  defp dedup_sql do
    case Regex.run(~r/@dedup_sql\s+"""\n(.*?)"""/s, File.read!(@migration)) do
      [_, sql] -> sql
      _ -> flunk("could not extract @dedup_sql from #{@migration}")
    end
  end

  describe "connect_provider/4 upsert" do
    test "reconnecting the same kind rotates the credential on ONE row" do
      team = team_fixture()

      {:ok, first} = Registry.connect_provider(team, "hetzner", "hz-token-original")
      {:ok, second} = Registry.connect_provider(team, "hetzner", "hz-token-rotated")

      assert [only] = Registry.list_providers(team)
      assert only.id == first.id, "the upsert must keep the original row, not mint a new one"
      assert second.id == first.id
      assert token_of(only) == "hz-token-rotated"
      assert token_of(second) == "hz-token-rotated"
    end

    test "returning: true hands back the row Postgres kept, not a half-invented struct" do
      team = team_fixture()

      {:ok, first} = Registry.connect_provider(team, "hetzner", "hz-a", label: "old label")
      {:ok, second} = Registry.connect_provider(team, "hetzner", "hz-b", label: "new label")

      # The conflict branch keeps the ORIGINAL id/inserted_at and replaces the
      # label/credential/updated_at — all four facts come back from the DB.
      assert second.id == first.id
      assert second.inserted_at == first.inserted_at
      assert second.label == "new label"
      assert DateTime.compare(second.updated_at, first.updated_at) in [:gt, :eq]
    end

    test "a reconnect with NO label keeps the one already there (review fix)" do
      team = team_fixture()

      {:ok, first} = Registry.connect_provider(team, "hetzner", "hz-a", label: "prod key")
      # `POST /v1/providers` reads `label` straight off the body and the SPA
      # omits the key when the field is blank — so this is the shape a real
      # re-submit takes, and an unconditional {:replace, [:label, …]} would
      # silently blank a credential the operator had named.
      {:ok, second} = Registry.connect_provider(team, "hetzner", "hz-b")

      assert second.id == first.id
      assert second.label == "prod key", "a nameless reconnect must not wipe the label"
      assert token_of(second) == "hz-b", "…while still rotating the credential"

      # And naming one still renames it.
      {:ok, third} = Registry.connect_provider(team, "hetzner", "hz-c", label: "rotated key")
      assert third.label == "rotated key"
    end

    test "the migration really left a UNIQUE index behind (not a plain one)" do
      # Proven by reading the schema rather than by provoking a violation: a
      # constraint error would abort the surrounding sandbox transaction, and a
      # test that leaves the connection unusable is worse than one that reads
      # the catalog. `indexdef` is Postgres' own rendering of the index.
      %Postgrex.Result{rows: rows} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE tablename = 'providers' AND indexname = $1",
          [@index_name]
        )

      assert [[indexdef]] = rows
      assert indexdef =~ "CREATE UNIQUE INDEX"
      assert indexdef =~ "team_id"
      assert indexdef =~ "kind"
    end

    test "kinds and teams are still independent — the index is per (team, kind)" do
      team = team_fixture()
      other = team_fixture()

      {:ok, _} = Registry.connect_provider(team, "hetzner", "hz-token")
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf-token")
      {:ok, _} = Registry.connect_provider(other, "hetzner", "hz-other-token")

      assert length(Registry.list_providers(team)) == 2
      assert [one] = Registry.list_providers(other)
      assert token_of(one) == "hz-other-token"
    end
  end

  describe "the rotation signal the console renders" do
    @app_js Path.expand("../../priv/static/app.js", __DIR__)

    test "BOTH replace arms move updated_at past inserted_at — the only visible mark of a rotation" do
      team = team_fixture()

      # The nameless re-submit (the SPA omits `label` when the box is blank) →
      # {:replace, [:encrypted_token, :updated_at]}.
      {:ok, first} = Registry.connect_provider(team, "hetzner", "hz-a", label: "prod key")

      assert DateTime.compare(first.inserted_at, first.updated_at) == :eq,
             "a FIRST connect fills both stamps from one autogenerate entry — nothing to report"

      {:ok, nameless} = Registry.connect_provider(team, "hetzner", "hz-b")

      assert nameless.inserted_at == first.inserted_at

      assert DateTime.compare(nameless.inserted_at, nameless.updated_at) == :lt,
             "dropping :updated_at from the no-label replace arm leaves the row looking untouched"

      # The named re-submit → {:replace, [:label, :encrypted_token, :updated_at]}.
      {:ok, named} = Registry.connect_provider(team, "cloudflare", "cf-a")
      {:ok, renamed} = Registry.connect_provider(team, "cloudflare", "cf-b", label: "rotated key")

      assert renamed.inserted_at == named.inserted_at
      assert renamed.label == "rotated key"

      assert DateTime.compare(renamed.inserted_at, renamed.updated_at) == :lt,
             "dropping :updated_at from the labelled replace arm leaves the row looking untouched"
    end

    test "the console still OFFERS the rotation this upsert makes safe (client↔server drift guard)" do
      # The server half of this pair has been true since the unique index landed;
      # the client half was stale for weeks, telling operators to destroy a
      # working credential first. Reading app.js here is what makes the pair fail
      # together: relax either side and this test reds.
      src = File.read!(@app_js)

      refute src =~ "Disconnect one above to replace its credentials",
             "the destroy-first copy is back — the card no longer offers in-place rotation"

      refute src =~ "o.kind === selected && !o.connected",
             "an armed-selection filter is excluding connected kinds again (check BOTH copies)"

      refute src =~ "silently ADDITIVE server-side",
             "the pre-index explanation is back, and it is false"

      assert src =~ "credential updated ",
             "the roster stopped rendering the rotation, so a successful replace is invisible"

      assert src =~ "p.updated_at !== p.inserted_at",
             "the roster stopped reading updated_at — provider_json/1's rotation signal is unused"
    end
  end

  describe "the migration's dedup DELETE" do
    test "collapses a genuine duplicate pair to the NEWEST row" do
      team = team_fixture()

      # DDL inside the sandbox transaction: dropped for this test only, restored
      # by the rollback. Without this the seed below is impossible — which is
      # exactly the guarantee the upsert now gives production.
      Repo.query!("DROP INDEX #{@index_name}")

      older = ~U[2026-01-01 00:00:00.000000Z]
      newer = ~U[2026-06-01 00:00:00.000000Z]

      {2, _} =
        Repo.insert_all(Provider, [
          raw_row(team, "hetzner", BarkparkCloud.Registry.Vault.encrypt("hz-stale"), older),
          raw_row(team, "hetzner", BarkparkCloud.Registry.Vault.encrypt("hz-current"), newer)
        ])

      assert length(Registry.list_providers(team)) == 2, "the duplicate seed must be real"

      Repo.query!(dedup_sql())

      assert [survivor] = Registry.list_providers(team)
      assert survivor.inserted_at == newer
      assert token_of(survivor) == "hz-current"

      # The index can now be created — the whole point of the DELETE.
      Repo.query!("CREATE UNIQUE INDEX #{@index_name} ON providers (team_id, kind)")
    end

    test "is a no-op when there is nothing to dedup (the live-prod shape)" do
      team = team_fixture()
      {:ok, kept} = Registry.connect_provider(team, "hetzner", "hz-only")

      %Postgrex.Result{num_rows: deleted} = Repo.query!(dedup_sql())

      assert deleted == 0
      assert [survivor] = Registry.list_providers(team)
      assert survivor.id == kept.id
      assert token_of(survivor) == "hz-only"
    end
  end

  defp raw_row(team, kind, ciphertext, at) do
    %{
      id: Ecto.UUID.generate(),
      team_id: team.id,
      kind: kind,
      label: nil,
      encrypted_token: ciphertext,
      inserted_at: at,
      updated_at: at
    }
  end
end
