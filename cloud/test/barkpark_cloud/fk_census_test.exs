defmodule BarkparkCloud.FkCensusTest do
  @moduledoc """
  FK-census tripwire (felix W20 scar-class, cloud/ sweep). Reflection test: every
  belongs_to FK column a changeset CASTS must declare a matching :foreign_key
  constraint (assoc_constraint OR foreign_key_constraint), and every declared
  constraint NAME must exist in live pg_constraint for that (table, column) — so a
  name-mismatch "inert translator" (a declared constraint whose default name
  misses the real pg constraint) is caught, not just a missing one.

  This closes the FK-abort scar-class AS A CLASS for the cloud/ control-plane app:
  the same raw `Ecto.ConstraintError` 500 (instead of `{:error, changeset}`) that
  E7 swept in `api/lib/barkpark` cannot re-enter cloud/ without a new schema
  landing RED here first. W18's census found ~17 shape-match cloud/ files; the
  W20 re-census on origin/main found ZERO genuine (unsealed) instances — every
  belongs_to FK already declares its constraint. This test is the tripwire that
  keeps it that way.

  ## Mutation proof (merge criterion)

  Comment out one real assoc_constraint (e.g. `agent_event.ex`
  `assoc_constraint(:barkpark)`) and the census goes RED with `:missing_constraint`
  for `:barkpark_id`; declare a wrong constraint `name:` and it goes RED with
  `:inert_name`; restore and it goes GREEN with an empty `git diff cloud/lib`.
  (The example named `env_var.ex` until that schema was deleted with the team
  env-var feature — cch-w53-bl, Option A, 2026-09-02.)

  ## Authority + local-drift caveat

  CI (`cloud.yml`, fresh `mix ecto.create` + `mix ecto.migrate` on an empty
  Postgres) is the AUTHORITY for this test. A local, long-lived, shared
  `barkpark_cloud_test` DB can DRIFT from the migration set — a stale/renamed
  constraint there can false-RED the `:inert_name` check even though CI is green.
  By design the harness is ROBUST to EXTRA live constraints (it only asserts that
  every DECLARED name is live and every CAST FK is declared; surplus pg_constraint
  rows never fail it, and every count floor is a `>=` minimum) — so drift can only
  ever produce a false RED, never a false GREEN. If a local run reds on
  `:inert_name` for a constraint that IS declared in the schema, re-run against a
  freshly migrated DB before trusting the failure.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Repo

  # ── Asserted exclusions (make-the-check-able-to-fail: no SILENT skip) ────────
  #
  # Every entry is a changeset-suffixed function this reflection cannot drive
  # generically, WITH a reason. The set is asserted to be EXACTLY these — a new
  # uninspectable changeset must be added here consciously.
  @excluded_changesets %{
    {BarkparkCloud.Notifications.EmailSettings, :chat_changeset, 4} =>
      "arity-4 (settings, attrs, valid_events, valid_channel_types) — needs vocab args, not callable generically; SPECIAL-CASED below with the real Notifications vocab"
  }

  # belongs_to-shaped columns with NO DB foreign key (plain binary_id) — nothing
  # to crosscheck. Documented for the record; the association enumeration never
  # surfaces these because they are declared as plain `field`, not `belongs_to`.
  @plain_binary_id_fields %{
    {BarkparkCloud.Registry.Site, :current_deployment_id} =>
      "plain binary_id field, no DB FK (breaks the site<->deployment FK cycle)"
  }

  # Changeset-bypass FK writes that no changeset can inspect. Documented; the
  # containment is code-review, not this reflection.
  @changeset_bypass_writes %{
    {BarkparkCloud.DeviceAuth, :approve, 2} =>
      "device_auth.ex approve/2 update_all sets user_id (bypasses changeset); unreachable-as-scar per W18"
  }

  # ── Count floors (provenance) ───────────────────────────────────────────────
  #
  # These `>=` minimums are anti-vacuous-green tripwires, NOT exact counts (the
  # census must never silently go green on 0 loaded modules — see the
  # Code.ensure_loaded?/1 note in cloud_schemas/0). The 19 floor derives from the
  # W18 felix census (~17 shape-match files) reconciled against the W20 re-census
  # on origin/main, which enumerated >= 19 belongs_to-bearing cloud schemas / FK
  # casts / live pg FK constraints. Growth only ever RAISES these; a drop below 19
  # means the reflection stopped seeing the schema surface and must be investigated.
  @schema_floor 19
  @fk_cast_floor 19
  @pg_fk_floor 19

  defp cloud_schemas do
    {:ok, mods} = :application.get_key(:barkpark_cloud, :modules)

    mods
    # Code.ensure_loaded?/1 BEFORE function_exported?/3: in a fresh VM the modules
    # may not be loaded yet, and function_exported? returns false for an unloaded
    # module — which would make this whole census VACUOUSLY green on 0 schemas
    # (the first spike run hit exactly this). ensure_loaded?/1 forces the load.
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.filter(&function_exported?(&1, :__schema__, 1))
    # keep only real Ecto schemas (have a source table), drop embedded_schema
    |> Enum.filter(fn m ->
      try do
        is_binary(m.__schema__(:source))
      rescue
        _ -> false
      end
    end)
    |> Enum.sort()
  end

  defp belongs_to_assocs(mod) do
    for a <- mod.__schema__(:associations),
        %Ecto.Association.BelongsTo{owner_key: ok} = refl <- [mod.__schema__(:association, a)] do
      {a, ok, refl}
    end
  end

  defp arity2_changesets(mod) do
    mod.__info__(:functions)
    |> Enum.filter(fn {name, arity} ->
      arity == 2 and String.ends_with?(Atom.to_string(name), "changeset")
    end)
  end

  # Live pg_constraint: %{conname => {table, column}} for single-column FKs.
  defp live_fk_constraints do
    sql = """
    SELECT c.conname, cl.relname AS tbl, a.attname AS col
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
    """

    Repo.query!(sql, []).rows
    |> Enum.reduce(%{}, fn [conname, tbl, col], acc ->
      Map.update(acc, conname, [{tbl, col}], &[{tbl, col} | &1])
    end)
  end

  # For a changeset's :foreign_key constraint, resolve constraint.field to the
  # owner_key column. field is the ASSOC name (assoc_constraint) OR the FK column
  # (foreign_key_constraint) — the DUAL match. (assoc_constraint on the 18 schemas
  # names the ASSOCIATION; foreign_key_constraint in usage/sample.ex names the
  # COLUMN — both must resolve.)
  defp field_to_owner_key(mod, field) do
    assocs = belongs_to_assocs(mod)

    cond do
      # assoc_constraint: field == association name
      match = Enum.find(assocs, fn {a, _ok, _r} -> a == field end) ->
        {_a, ok, _r} = match
        ok

      # foreign_key_constraint: field == owner_key column directly
      Enum.any?(assocs, fn {_a, ok, _r} -> ok == field end) ->
        field

      true ->
        nil
    end
  end

  test "schema enumeration is non-empty and covers the known belongs_to schemas" do
    schemas = cloud_schemas()
    assert length(schemas) >= 1

    with_belongs_to = Enum.filter(schemas, &(belongs_to_assocs(&1) != []))

    # Silent-skip is a doctrine violation: assert we see >= the 19 known schemas.
    assert length(with_belongs_to) >= @schema_floor,
           "expected >= #{@schema_floor} belongs_to-bearing cloud schemas, saw #{length(with_belongs_to)}: " <>
             inspect(with_belongs_to)
  end

  test "exclusion list is exactly the asserted entries (no silent growth)" do
    # Every arity>2 changeset-suffixed fn on a belongs_to schema MUST be listed.
    # Kept EXACT (==, not subset) so a NEW arity!=2 changeset that this reflection
    # cannot drive fails here until it is consciously excluded or special-cased.
    uninspectable =
      for mod <- cloud_schemas(),
          belongs_to_assocs(mod) != [],
          {name, arity} <- mod.__info__(:functions),
          arity != 2,
          String.ends_with?(Atom.to_string(name), "changeset"),
          do: {mod, name, arity}

    listed = Map.keys(@excluded_changesets) |> Enum.sort()
    assert Enum.sort(uninspectable) == listed

    # Documented-but-not-enumerated corners carry a non-empty reason each.
    for {_k, reason} <- Map.merge(@plain_binary_id_fields, @changeset_bypass_writes) do
      assert is_binary(reason) and reason != ""
    end
  end

  test "every cast FK column declares a matching :foreign_key constraint whose name is live" do
    pg_fks = live_fk_constraints()

    assert map_size(pg_fks) >= @pg_fk_floor,
           "expected >= #{@pg_fk_floor} live FK constraints, saw #{map_size(pg_fks)}"

    problems =
      for mod <- cloud_schemas(),
          assocs = belongs_to_assocs(mod),
          assocs != [],
          table = mod.__schema__(:source),
          {fname, 2} <- arity2_changesets(mod),
          not Map.has_key?(@excluded_changesets, {mod, fname, 2}),
          reduce: [] do
        acc ->
          # Sentinel attrs: a random UUID for every FK column (string keys).
          attrs =
            for({_a, ok, _r} <- assocs, into: %{}, do: {Atom.to_string(ok), Ecto.UUID.generate()})

          cs =
            try do
              apply(mod, fname, [struct(mod), attrs])
            rescue
              e -> {:raised, e}
            end

          case cs do
            {:raised, e} ->
              [{mod, fname, :raised, Exception.message(e)} | acc]

            %Ecto.Changeset{} = cs ->
              # FK columns this changeset actually CAST.
              cast_fks =
                for {_a, ok, _r} <- assocs, Map.has_key?(cs.changes, ok), do: ok

              # :foreign_key constraints declared, resolved to owner_key columns.
              declared =
                for c <- cs.constraints,
                    c.type == :foreign_key,
                    ok = field_to_owner_key(mod, c.field),
                    ok != nil,
                    do: {ok, c.constraint}

              declared_cols = MapSet.new(declared, fn {ok, _name} -> ok end)

              # (a) every cast FK has a declared matching constraint
              missing =
                for ok <- cast_fks,
                    not MapSet.member?(declared_cols, ok),
                    do: {mod, fname, :missing_constraint, ok}

              # (b) every declared constraint NAME is live for (table, column)
              inert =
                for {ok, name} <- declared,
                    {table, Atom.to_string(ok)} not in Map.get(pg_fks, name, []),
                    do: {mod, fname, :inert_name, {name, table, ok, Map.get(pg_fks, name)}}

              missing ++ inert ++ acc
          end
      end

    assert problems == [], "FK-census violations:\n" <> Enum.map_join(problems, "\n", &inspect/1)
  end

  test "D121: EmailSettings.chat_changeset/4 declares a live :team FK (special-cased vocab)" do
    # chat_changeset/4 is arity-4 → EXCLUDED from the generic drive above (it needs
    # the Notifications-owned vocabulary, not a generic struct+attrs pair). It is
    # NOT left un-covered: this special case drives it with the REAL vocab and
    # asserts its :team :foreign_key constraint is declared AND live (dual-match).
    valid_events = Notifications.chat_events()
    valid_channel_types = Notifications.chat_channel_types()

    # Real vocab, not a stub: a known event + a known channel type must be present.
    assert "provision_failed" in valid_events,
           "expected real event vocab from Notifications.chat_events/0, saw: #{inspect(valid_events)}"

    assert "slack" in valid_channel_types,
           "expected real channel-type vocab from Notifications.chat_channel_types/0, saw: #{inspect(valid_channel_types)}"

    cs =
      EmailSettings.chat_changeset(
        %EmailSettings{},
        %{"team_id" => Ecto.UUID.generate()},
        valid_events,
        valid_channel_types
      )

    assert %Ecto.Changeset{} = cs

    # It CASTS the team_id FK column …
    assert Map.has_key?(cs.changes, :team_id),
           "chat_changeset/4 must cast :team_id"

    # … and DECLARES a :foreign_key constraint on the :team association.
    team_fk = Enum.find(cs.constraints, fn c -> c.type == :foreign_key and c.field == :team end)

    assert team_fk,
           "chat_changeset/4 must declare assoc_constraint(:team); constraints: " <>
             inspect(cs.constraints)

    # dual-match: the assoc name :team resolves to the owner_key column :team_id.
    assert field_to_owner_key(EmailSettings, team_fk.field) == :team_id

    # … and that constraint NAME is LIVE in pg_constraint for (table, team_id) —
    # so a rename that leaves the changeset pointing at a phantom name is caught.
    pg_fks = live_fk_constraints()
    table = EmailSettings.__schema__(:source)

    assert {table, "team_id"} in Map.get(pg_fks, team_fk.constraint, []),
           "chat_changeset/4 :team constraint #{inspect(team_fk.constraint)} is not live for " <>
             "#{table}.team_id; live rows for that name: " <>
             inspect(Map.get(pg_fks, team_fk.constraint))
  end

  test "DIAGNOSTIC: prove the census is not vacuously green" do
    schemas = cloud_schemas()
    bt = Enum.filter(schemas, &(belongs_to_assocs(&1) != []))
    total_belongs_to = bt |> Enum.flat_map(&belongs_to_assocs/1) |> length()
    pg_fks = live_fk_constraints()

    # Count FK columns actually EXERCISED (cast + matched) across all changesets.
    {checked_fk_casts, matched_names} =
      for mod <- schemas,
          assocs = belongs_to_assocs(mod),
          assocs != [],
          {fname, 2} <- arity2_changesets(mod),
          not Map.has_key?(@excluded_changesets, {mod, fname, 2}),
          reduce: {0, MapSet.new()} do
        {n, names} ->
          attrs =
            for {_a, ok, _r} <- assocs, into: %{}, do: {Atom.to_string(ok), Ecto.UUID.generate()}

          case apply(mod, fname, [struct(mod), attrs]) do
            %Ecto.Changeset{} = cs ->
              casts = for {_a, ok, _r} <- assocs, Map.has_key?(cs.changes, ok), do: ok
              fk_names = for c <- cs.constraints, c.type == :foreign_key, do: c.constraint
              {n + length(casts), Enum.reduce(fk_names, names, &MapSet.put(&2, &1))}

            _ ->
              {n, names}
          end
      end

    IO.puts("""

    ── FK-census diagnostic ──────────────────────────────
    ecto schemas enumerated ......... #{length(schemas)}
    belongs_to-bearing schemas ...... #{length(bt)}
    total belongs_to associations ... #{total_belongs_to}
    live FK constraints (pg) ........ #{map_size(pg_fks)}
    FK-column casts checked ......... #{checked_fk_casts}
    distinct declared constraints ... #{MapSet.size(matched_names)}
    ──────────────────────────────────────────────────────
    """)

    assert length(bt) >= @schema_floor
    assert checked_fk_casts >= @fk_cast_floor
    assert map_size(pg_fks) >= @pg_fk_floor
  end
end
