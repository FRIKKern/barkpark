defmodule BarkparkCloud.SiteCascadeCensusTest do
  @moduledoc """
  cloud-console-hardening W67 (charter D820) — the CASCADE census for `sites`.

  ## What this guards

  `DELETE /v1/sites/:id` tears the site down on its box FIRST and only then
  deregisters the row, with `{:ok, _} = Registry.delete_site(site)` — a strict
  match on a bare `Repo.delete` that declares no constraint. Every child row
  therefore has to be swept by the DATABASE. If any FK referencing `sites` were
  ever loosened to `ON DELETE RESTRICT` (or `NO ACTION`), that `Repo.delete`
  raises `Ecto.ConstraintError`, the router answers

      500 {"error":"server_error","request_id":"…"}

  and — because the box half already ran — the site's Caddy route is disarmed
  while the registration SURVIVES. The INVERSE ORPHAN: a dead site that is still
  registered, reported by an envelope carrying no `ok` and no `detail`.

  ## Why it did not exist before, and what it caught

  Three FKs reference `sites` (`content_publishes`, `deployments`,
  `site_artifacts`) and only ONE of them — deployments — was asserted anywhere,
  behaviourally, in `router_sites_test.exs`. `confdeltype` appeared in zero bytes
  of `cloud/`. Measured by mutation on 2026-08-10: flipping
  `site_artifacts.site_id` to `ON DELETE RESTRICT` and driving the route produced
  exactly the 500 above with the box teardown already done and the row surviving,
  while `fk_census_test.exs` stayed 5/0 and the whole `router_sites_test.exs`
  stayed 104/0. Nothing in the repo noticed. (`RESTRICT` is checked IMMEDIATELY,
  not at end of statement, so the deployments cascade does not rescue an artifact
  bound to a deployment either: a regression here bricks delete for every site
  that ever deployed.)

  ## Why the EXACT SET, not "every FK to sites is cascade"

  An "every FK referencing sites carries confdeltype='c'" assertion is GREEN on a
  brand-new child table the moment that table gets it right, and green forever
  after — including for the case that actually happened. `content_publishes` was
  created by `20260807130000_create_content_publishes.exs` on 2026-08-07 and
  entered the delete path with NO behavioural cover and no census row at all; a
  universally-quantified form would never have said a word about it. The exact
  set is what makes a NEW child of `sites` red here, and the red is the prompt to
  go write its delete-path cover in `router_sites_test.exs` (which this wave did
  for both unasserted children).

  `@site_children` is therefore a REGISTER, not a filter: adding a row to it is
  the conscious act of accepting a new table into the site-delete blast radius.

  ## The FK-less child

  The second half of the census asks Postgres for every table in schema `public`
  carrying a `site_id` COLUMN and requires it to be in the same register — so a
  child added with a bare `site_id` and no foreign key at all (which cascades
  nothing, and leaves rows pointing at a deleted site forever) is caught by the
  column, not by the constraint it forgot to declare.

  ## Mutation proof (all three arms red; run 2026-08-10, W67 S2)

    * `site_artifacts.site_id` → `ON DELETE RESTRICT`: "every FK referencing
      `sites` is ON DELETE CASCADE" fails with
      `site_artifacts.site_id (site_artifacts_site_id_fkey) is confdeltype "r"`.
    * `content_publishes.site_id` → `ON DELETE RESTRICT`: same test, same shape,
      naming `content_publishes_site_id_fkey`.
    * a NEW `site_notes(site_id uuid REFERENCES sites ON DELETE CASCADE)`: the
      exact-set test fails with `unexpected FK children of sites:
      [{"site_notes", "site_id"}]`, AND the site_id-column test fails with
      `tables carrying a site_id column but absent from the census: ["site_notes"]`
      — i.e. the new-table arm reds even though the new FK is a correct cascade.

  Authority is CI (`cloud.yml`, a fresh `mix ecto.create` + `mix ecto.migrate`),
  same as `fk_census_test.exs`: a long-lived local test DB can drift from the
  migration set, and drift here can only ever produce a false RED.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Repo

  # The EXACT register of child (table, column) pairs that a site delete sweeps.
  # Each value is the reason that table is in the blast radius — a new entry is a
  # deliberate act, and the test below fails until it is made.
  @site_children %{
    {"deployments", "site_id"} =>
      "every build ever enqueued for the site; asserted behaviourally at router_sites_test.exs " <>
        "\"tears the site down on the box, THEN deregisters the row (deployments cascade)\"",
    {"site_artifacts", "site_id"} =>
      "uploaded prebuilt tarballs (site-spawner W9 / D91); a RESTRICT here bricks delete for " <>
        "every site that ever uploaded one, bound to a deployment or not",
    {"content_publishes", "site_id"} =>
      "one row per HMAC-verified content-publish delivery (deploy-reliability W11 / D162); " <>
        "created 2026-08-07 and unasserted from birth until W67"
  }

  @cascade "c"

  # Live FKs referencing `sites`: [{child_table, child_column, confdeltype, conname}].
  defp site_fks do
    sql = """
    SELECT cl.relname AS child, a.attname AS col, c.confdeltype, c.conname
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN pg_class p ON p.oid = c.confrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    JOIN unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f' AND p.relname = 'sites' AND n.nspname = 'public'
    """

    Repo.query!(sql, []).rows
    |> Enum.map(fn [child, col, del, name] -> {child, col, to_string(del), name} end)
  end

  defp tables_with_site_id do
    sql = """
    SELECT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.column_name = 'site_id'
      AND c.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
    """

    Repo.query!(sql, []).rows |> List.flatten() |> Enum.sort()
  end

  test "the `sites` table exists and has children (the census is not vacuously green)" do
    # Without this, a typo in the query's `p.relname` would make every set below
    # compare empty-to-empty on a MISSING register and pass for the wrong reason.
    assert Repo.query!("SELECT to_regclass('public.sites')::text", []).rows == [["sites"]],
           "public.sites is missing — this census is measuring nothing"

    assert site_fks() != [], "no FK references `sites` at all; the census query is broken"
    assert @site_children != %{}
  end

  test "the FKs referencing `sites` are EXACTLY the census register (a new child table reds)" do
    live = MapSet.new(site_fks(), fn {child, col, _del, _name} -> {child, col} end)
    expected = MapSet.new(Map.keys(@site_children))

    unexpected = MapSet.difference(live, expected) |> Enum.sort()
    missing = MapSet.difference(expected, live) |> Enum.sort()

    assert unexpected == [],
           "unexpected FK children of sites: #{inspect(unexpected)}\n" <>
             "A new table now cascades (or refuses) on site delete. Give it behavioural cover " <>
             "in router_sites_test.exs's DELETE /v1/sites/:id describe block, then add it to " <>
             "@site_children with the reason it belongs in the blast radius."

    assert missing == [],
           "census names FK children of sites that no longer exist: #{inspect(missing)}\n" <>
             "If the table was dropped, drop its @site_children row too."
  end

  test "every FK referencing `sites` is ON DELETE CASCADE (confdeltype='c')" do
    offenders =
      for {child, col, del, name} <- site_fks(), del != @cascade do
        "#{child}.#{col} (#{name}) is confdeltype #{inspect(del)}, expected #{inspect(@cascade)}"
      end

    assert offenders == [],
           "site-delete cascade regression — `{:ok, _} = Registry.delete_site(site)` in " <>
             "router.ex is a strict match on a bare Repo.delete, so a non-cascade FK raises " <>
             "Ecto.ConstraintError AFTER the box teardown already ran: 500 server_error, box " <>
             "torn down, site row surviving.\n" <> Enum.join(offenders, "\n")
  end

  test "every table carrying a `site_id` column is in the census (catches an FK-less child)" do
    expected = @site_children |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    live = tables_with_site_id()

    assert live -- expected == [],
           "tables carrying a site_id column but absent from the census: " <>
             "#{inspect(live -- expected)}\n" <>
             "A child with a bare site_id and NO foreign key cascades NOTHING: its rows outlive " <>
             "the site forever. Declare the FK with on_delete: :delete_all, cover it in " <>
             "router_sites_test.exs, then register it in @site_children."

    assert expected -- live == [],
           "census names site_id-carrying tables that do not exist: #{inspect(expected -- live)}"
  end

  test "DIAGNOSTIC: the measured census, printed" do
    fks = site_fks()

    IO.puts("""

    ── site-delete cascade census ────────────────────────
    FKs referencing sites ........... #{length(fks)}
    tables with a site_id column .... #{length(tables_with_site_id())}
    #{Enum.map_join(Enum.sort(fks), "\n", fn {c, col, del, name} -> "  #{c}.#{col} confdeltype=#{del} (#{name})" end)}
    ──────────────────────────────────────────────────────
    """)

    assert length(fks) == map_size(@site_children)
  end
end
