defmodule Barkpark.PluginFreeBootTest do
  @moduledoc """
  Goal barkpark-G1 — regression bar for the fresh-install invariant.

  Barkpark must boot, serve Studio, and serve `/api/schemas` with no plugins
  loaded. This case stops `:barkpark`, sets `:plugins` to `[]`, restarts the
  app, and asserts a 5-tier set of invariants over the live system:

    1. The supervision tree has no `Barkpark.Plugins.OnixEdit.*` children.
    2. `GET /studio/production` (following the scoped-shell redirect)
       renders 200 with the `"Structure"` marker.
    3. `GET /api/schemas` returns exactly the 6 PUBLIC seed schema names
       (5 public demo seeds + the CORE `tag` schema, charter D12).

       AMENDED — api-read-path-security-sweep w2. This row asserted 9 names
       (all 8 demo seeds + `tag`), which encoded the anon field-disclosure
       defect as an invariant: the route is deliberately un-token-gated and
       served full `fields` for the three `visibility: "private"` demo seeds
       (`siteSettings`, `navigation`, `colors` — seeds/demo.ex:185/212/226) to
       any anonymous reader. `LegacyController.schemas/2` now filters through
       `Schema.public_schema?/1`, so those three drop out. The invariant is
       UNWEAKENED in kind — still exact set equality over a fresh install,
       still non-empty, and still derived from the seeds rather than a
       hardcoded product list; only the anonymous-visible half is asserted now.
    4. Studio HTML contains no plugin-specific tokens
       (`OnixEdit`, `Bokbasen`, `book`).
    5. Host code under `lib/barkpark` + `lib/barkpark_web` couples to a
       REMOVABLE plugin (every namespace in `priv/plugins/*/plugin.json`,
       not just OnixEdit) only within the reviewed allowlist
       `@sanctioned_host_plugin_coupling`. Detection is AST-based (real
       `__aliases__` references, not text — a `@moduledoc`/comment mention is
       not a coupling); the detected set must EQUAL the allowlist, so a NEW
       core→disabled-plugin reach reds the gate.
    6. The authoring-excellence publish wall holds with all plugins off:
       an unknown-tag publish over HTTP is still a 422 `unknown_tag` —
       core enforcement, provably not plugin-carried.

  Tagged `:boot_test` — excluded from the default `mix test` run (it stops
  and restarts the whole application, which no async suite survives). Invoke
  explicitly:

      mix test --only boot_test test/barkpark/plugin_free_boot_test.exs

  This is the regression bar that keeps the fresh-install invariant from
  drifting in future PRs. (Wiring it into CI is backlog `ae-boot-gate-ci`.)
  """

  use ExUnit.Case, async: false

  @moduletag :boot_test

  import Phoenix.ConnTest
  # `put_req_header/3` (used to attach Bearer tokens) and `get_resp_header/2`
  # (used to follow the Studio scoped-shell redirect) live in Plug.Conn, which
  # Phoenix.ConnTest does not re-export — import them directly.
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  @endpoint BarkparkWeb.Endpoint

  # The 5 PUBLIC demo seed schemas PLUS the core `tag` schema (authoring-
  # excellence charter D12 — registered by SchemaBootstrap from CORE, present
  # even with every plugin off; `tag_registry.ex:78` declares it public).
  # Growing this list is a deliberate act: a 7th name must be added here
  # explicitly, never drift in silently (Q6 locked).
  #
  # The three demo seeds NOT here — `siteSettings`, `navigation`, `colors` —
  # are `visibility: "private"` (seeds/demo.ex:185/212/226) and are withheld
  # from the anonymous `/api/schemas` index by the `Schema.public_schema?/1`
  # filter in `LegacyController.schemas/2` (api-read-path-security-sweep w2).
  # A private seed appearing here again means that filter regressed.
  @expected_seed_schemas ~w(post page author category project tag)

  # ── Tier-5 allowlist: sanctioned host→removable-plugin code coupling ──────
  #
  # Baseline measured 2026-07-11 (felix, task-2bfe34a98d53be8a) by AST scan of
  # every host `.ex` under lib/barkpark + lib/barkpark_web (excluding
  # lib/barkpark/plugins/) for real `__aliases__` references to a REMOVABLE
  # plugin namespace (the modules registered in priv/plugins/*/plugin.json).
  #
  # Each entry is `{plugin_module, host_file}`. The groups below record WHY
  # each coupling is legitimate — the difference between an enforced invariant
  # and a decorative one. Tier 5 asserts the AST-detected coupling set EQUALS
  # the union of these groups: a NEW reference reds as an unreviewed coupling;
  # a removed one reds as a stale entry (prune it).
  #
  # Namespaces with ZERO sanctioned host coupling (OnixEdit, Frt, Pulse, Quiz)
  # are deliberately absent — any host reference to them reds immediately.

  # host-owns-ALL-Studio-UI: a plugin ships no UI (same contract), so the
  # host's SheetGrid family + studio_live necessarily name Sheets.* render /
  # session helpers. Inherent Studio coupling, not a runtime reach.
  @coupling_studio_ui [
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/sheet_grid.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/sheet_grid/cells.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/sheet_grid/filter.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/sheet_grid/geometry.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/sheet_grid/grid_data.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/sheet_grid/ops.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark_web/live/studio/studio_live/shared.ex"}
  ]

  # host owns the public reader LiveView (the Bulldocs reader at /papers/:slug
  # renders `Barkpark.Plugins.Bulldocs.Events`).
  @coupling_public_reader_ui [
    {"Barkpark.Plugins.Bulldocs", "lib/barkpark_web/live/bulldocs_live.ex"}
  ]

  # core-static, always present: application.ex declares the Sheets session
  # supervisor as a static child. Per api/CLAUDE.md the Sheets session runtime
  # is CORE, plugin-independent — it does NOT vanish under :plugins [].
  @coupling_core_static [
    {"Barkpark.Plugins.Sheets", "lib/barkpark/application.ex"}
  ]

  # plugin HTTP wiring: host controllers/plugs that back a plugin's
  # `register_routes/1` surface. They execute ONLY when that plugin mounted its
  # routes (e.g. the `:ticket_key` / `:github_webhook` pipelines carry only
  # `plugin_routes(...)`), so they never run under :plugins []. Audit felix-d03
  # confirmed the Github & Tickets reaches are guarded — no crash under the
  # kill switch.
  @coupling_plugin_http [
    {"Barkpark.Plugins.Bulldocs", "lib/barkpark_web/controllers/bulldocs_intents_controller.ex"},
    {"Barkpark.Plugins.Github", "lib/barkpark_web/controllers/github_adopt_controller.ex"},
    {"Barkpark.Plugins.Github", "lib/barkpark_web/controllers/github_status_controller.ex"},
    {"Barkpark.Plugins.Github", "lib/barkpark_web/controllers/github_webhook_controller.ex"},
    {"Barkpark.Plugins.Github", "lib/barkpark_web/plugs/github_webhook_signature.ex"},
    {"Barkpark.Plugins.Tickets", "lib/barkpark_web/controllers/ticket_keys_controller.ex"},
    {"Barkpark.Plugins.Tickets",
     "lib/barkpark_web/controllers/tickets_attachments_controller.ex"},
    {"Barkpark.Plugins.Tickets", "lib/barkpark_web/controllers/tickets_controller.ex"},
    {"Barkpark.Plugins.Tickets", "lib/barkpark_web/plugs/require_ticket_key.ex"}
  ]

  # guarded runtime reaches: core code that MAY call a plugin, but only behind
  # a data-existence check / documented no-op for non-matching docs. The
  # monorepo keeps the module compiled, so there is no UndefinedFunctionError;
  # audit felix-d03 confirmed no crash under :plugins []. These are the
  # accidental-class couplings the broadened guard now TRACKS so a NEW one
  # gets review. `render/walk.ex` is the compile-time Sheets error-vocabulary
  # edge (finding F2, filed task-b88cd354c8ccaca3 — fixed separately).
  @coupling_guarded_runtime [
    {"Barkpark.Plugins.Media", "lib/barkpark/media.ex"},
    {"Barkpark.Plugins.Media", "lib/barkpark/media/delivery/asset_response.ex"},
    # `V1.MediaController.asset_doc/2` (task-d55b02001cf589f0) calls the SAME
    # `PluginAssets.file_scope_opts/1` the asset_response.ex reach directly
    # above already sanctions — pure over the `%MediaFile{}` row (workspace_id/
    # project_id -> a scope keyword list, no DB/network/config touch), so it is
    # identical, not merely similar, under `:plugins []`.
    {"Barkpark.Plugins.Media", "lib/barkpark_web/controllers/v1/media_controller.ex"},
    {"Barkpark.Plugins.Media", "lib/barkpark/media/processing.ex"},
    {"Barkpark.Plugins.Media", "lib/barkpark/media/storage/checkout.ex"},
    {"Barkpark.Plugins.Media", "lib/barkpark/media/storage/collections.ex"},
    {"Barkpark.Plugins.Media", "lib/barkpark/media/storage/relations.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark/content/sheets.ex"},
    {"Barkpark.Plugins.Sheets", "lib/barkpark/portable_doc/render/walk.ex"},
    {"Barkpark.Plugins.Bulldocs", "lib/barkpark/content/papers/block_ops.ex"},
    {"Barkpark.Plugins.Tasks", "lib/barkpark/edge_projector/backfill.ex"},
    {"Barkpark.Plugins.Tasks", "lib/barkpark/edge_projector/projector_worker.ex"},
    {"Barkpark.Plugins.Github", "lib/barkpark/tasks/board.ex"},
    # The close-time ACKNOWLEDGEMENT gate (the reporter loop). `Tasks.Close`
    # calls five functions on `Github.Acknowledgement` — `intake_born?/2`,
    # `acknowledged?/1`, `has_criterion?/1`, `issue_number/1`,
    # `criterion_indices/1` — and every one of them is PURE over the doc's own
    # `content` map. None reads `Settings`, `Auth`, `Client`, config, the
    # network, or the DB; the module's one DB-touching function (`census/2`) is
    # called ONLY by `Github.Health`, which is inside the plugin namespace.
    #
    # Under `:plugins []` the behaviour is therefore not merely non-crashing but
    # IDENTICAL: a doc with no `content.github` fails `intake_born?/2`, the gate
    # returns `{:ok, nil}`, and the close path is byte-for-byte what it was
    # before this coupling existed. Pinned by
    # `Barkpark.Tasks.CloseAcknowledgementTest`, which closes both a plain task
    # and an outbound-mirrored one and asserts no `close_override` key appears.
    {"Barkpark.Plugins.Github", "lib/barkpark/tasks/close.ex"}
  ]

  @sanctioned_host_plugin_coupling @coupling_studio_ui ++
                                     @coupling_public_reader_ui ++
                                     @coupling_core_static ++
                                     @coupling_plugin_http ++
                                     @coupling_guarded_runtime

  # `:persistent_term` keys that the plugin layer writes during a normal
  # boot. They survive `Application.stop` because persistent_term is
  # process-independent — when this case runs AFTER a prior test that
  # populated them with OnixEdit's contributions, a stale snapshot can
  # leak `book` / `Bokbasen` tokens into the "fresh" boot below.
  #
  # Erase before `ensure_all_started/1` so the fresh app starts with empty
  # caches. Defence-in-depth: G5.s2's discovery kill-switch (Registry now
  # respects `:plugins=[]` and short-circuits the disk walk) is the
  # primary fix; this purge guarantees no pre-existing snapshot can
  # contaminate the boot path even if the kill-switch had a regression.
  @plugin_snapshot_keys [
    {Barkpark.Plugins.Registry, :snapshot}
  ]

  setup_all do
    prev_plugins = Application.get_env(:barkpark, :plugins, :unset)

    Application.put_env(:barkpark, :plugins, [])
    Application.stop(:barkpark)

    # Erase plugin-derived `:persistent_term` snapshots that survive
    # `Application.stop`. See @plugin_snapshot_keys for the list and
    # rationale.
    Enum.each(@plugin_snapshot_keys, &:persistent_term.erase/1)

    {:ok, _} = Application.ensure_all_started(:barkpark)

    # The Repo restart wipes the previous sandbox-mode setting. Restore the
    # manual/shared chain the rest of the suite assumes, then take a
    # connection so the in-process Endpoint pipeline can read.
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

    # `Application.put_env(:plugins, [])` flips the config but does not
    # purge plugin-contributed rows that earlier test runs (or a prior
    # `mix ecto.reset`) persisted in `schema_definitions` — most commonly
    # OnixEdit's `book` schema. Without this purge, assertion #3 ("exactly
    # the 9 seed names") sees `book` and fails. Q6 of the G1 grill locks
    # the name list — growing it (as the core `tag` schema did, 8→9) must
    # be an explicit assertion update here, never silent drift.
    #
    # Two races to dodge before we delete + reseed:
    #
    #   1. The post-boot Task in `Barkpark.Application.start/2` calls
    #      `Plugins.Registry.discover_and_register/0`, which walks
    #      `priv/plugins/` from disk and re-registers OnixEdit regardless
    #      of the `:plugins` env override. It then calls
    #      `Bootstrap.register_all_schemas/0`, which re-inserts `book`
    #      via the SHARED sandbox connection we just installed.
    #
    #   2. If we delete_all + reseed BEFORE that Task finishes, the
    #      Task's later `upsert_schema("book", …)` lands AFTER our
    #      reseed and assertion #3 sees 9 names.
    #
    # Wait for the Task.Supervisor to drain, THEN purge + reseed.
    wait_for_post_boot_task_to_finish()

    # Reseed under the SAME Default scope the flat routes' AssignDefaultScope
    # plug resolves at request time. The reseed used to insert nil-scope rows
    # directly, but /api/schemas reads scope-filtered (list_schemas →
    # scope_to_workspace_or_global) — nil-scope rows are invisible to it, so
    # assertion #3 saw []. Stamping the Default scope on the write makes the
    # test exercise the exact read the endpoint serves.
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    Barkpark.Repo.delete_all(Barkpark.Content.SchemaDefinition)
    reseed_host_schemas(workspace_id: ws.id, project_id: project.id)

    on_exit(fn ->
      Application.stop(:barkpark)

      case prev_plugins do
        :unset -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end

      {:ok, _} = Application.ensure_all_started(:barkpark)
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
    end)

    :ok
  end

  # Polls Barkpark.TaskSupervisor until it reports zero active children,
  # i.e. the post-boot one-shot Task has run to completion (or crashed).
  # Bounded at 5s — well above the disk-walk + per-plugin Bootstrap loop
  # under :shared sandbox mode in practice. On timeout we proceed anyway
  # rather than block the suite: the worst case is a race where `book`
  # leaks into assertion #3, which the regression bar will then catch.
  defp wait_for_post_boot_task_to_finish(deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_for_task_supervisor(deadline)
  end

  defp do_wait_for_task_supervisor(deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      Task.Supervisor.children(Barkpark.TaskSupervisor) == [] ->
        :ok

      true ->
        Process.sleep(25)
        do_wait_for_task_supervisor(deadline)
    end
  rescue
    # The supervisor process may not exist yet if ensure_all_started/1
    # is still wiring children. Yield and try again until the deadline.
    _ ->
      Process.sleep(25)
      do_wait_for_task_supervisor(deadline)
  end

  # The 8 demo seed schemas, inlined verbatim from `priv/repo/seeds.exs`
  # (the schema half — documents, dev token, codelist seeding skipped), plus
  # the CORE `tag` schema read from its single source of truth.
  #
  # Option B (inline) over option A (Code.eval_file seeds.exs) because
  # seeds.exs is monolithic: schema seeding is followed by 27 document
  # inserts, dev-token creation, plugin-Bootstrap, ONIX codelist seeding,
  # and Thema codelist seeding. The test only queries `/api/schemas` — the
  # extra inserts (especially ~28k codelist rows) are noise. Coupling the
  # test to the canonical seed-schema list IS the regression bar (Q6 locked).
  defp reseed_host_schemas(scope) do
    dataset = "production"

    host_specs = [
      %{
        name: "post",
        title: "Post",
        icon: "📄",
        visibility: "public",
        dataset: dataset,
        fields: [
          %{name: "title", title: "Title", type: "string"},
          %{name: "slug", title: "Slug", type: "slug"},
          %{
            name: "status",
            title: "Status",
            type: "select",
            options: ["draft", "published", "archived"]
          },
          %{name: "publishedAt", title: "Published At", type: "datetime"},
          %{name: "excerpt", title: "Excerpt", type: "text", rows: 3},
          %{name: "body", title: "Body", type: "richText"},
          %{name: "featuredImage", title: "Featured Image", type: "image"},
          %{name: "author", title: "Author", type: "reference", refType: "author"},
          %{name: "featured", title: "Featured Post", type: "boolean"}
        ]
      },
      %{
        name: "page",
        title: "Page",
        icon: "📑",
        visibility: "public",
        dataset: dataset,
        fields: [
          %{name: "title", title: "Title", type: "string"},
          %{name: "slug", title: "Slug", type: "slug"},
          %{name: "body", title: "Page Content", type: "richText"},
          %{name: "seoTitle", title: "SEO Title", type: "string"},
          %{name: "seoDescription", title: "SEO Description", type: "text", rows: 2},
          %{name: "heroImage", title: "Hero Image", type: "image"}
        ]
      },
      %{
        name: "author",
        title: "Author",
        icon: "👤",
        visibility: "public",
        dataset: dataset,
        fields: [
          %{name: "name", title: "Name", type: "string"},
          %{name: "slug", title: "Slug", type: "slug"},
          %{name: "bio", title: "Bio", type: "text", rows: 4},
          %{name: "avatar", title: "Avatar", type: "image"},
          %{name: "email", title: "Email", type: "string"},
          %{
            name: "role",
            title: "Role",
            type: "select",
            options: ["editor", "writer", "contributor", "admin"]
          }
        ]
      },
      %{
        name: "category",
        title: "Category",
        icon: "🏷",
        visibility: "public",
        dataset: dataset,
        fields: [
          %{name: "title", title: "Title", type: "string"},
          %{name: "slug", title: "Slug", type: "slug"},
          %{name: "description", title: "Description", type: "text", rows: 2},
          %{name: "color", title: "Color", type: "color"}
        ]
      },
      %{
        name: "project",
        title: "Project",
        icon: "💼",
        visibility: "public",
        dataset: dataset,
        fields: [
          %{name: "title", title: "Title", type: "string"},
          %{name: "slug", title: "Slug", type: "slug"},
          %{name: "client", title: "Client", type: "string"},
          %{
            name: "status",
            title: "Status",
            type: "select",
            options: ["planning", "active", "completed", "archived"]
          },
          %{name: "description", title: "Description", type: "richText"},
          %{name: "coverImage", title: "Cover Image", type: "image"},
          %{name: "startDate", title: "Start Date", type: "datetime"},
          %{name: "featured", title: "Featured", type: "boolean"}
        ]
      },
      %{
        name: "siteSettings",
        title: "Site Settings",
        icon: "⚙",
        visibility: "private",
        dataset: dataset,
        fields: [
          %{name: "title", title: "Site Title", type: "string"},
          %{name: "description", title: "Site Description", type: "text", rows: 2},
          %{name: "logo", title: "Logo", type: "image"},
          %{name: "analyticsId", title: "Analytics ID", type: "string"}
        ]
      },
      %{
        name: "navigation",
        title: "Navigation",
        icon: "🧭",
        visibility: "private",
        dataset: dataset,
        fields: [
          %{name: "title", title: "Menu Title", type: "string"}
        ]
      },
      %{
        name: "colors",
        title: "Brand Colors",
        icon: "🎨",
        visibility: "private",
        dataset: dataset,
        fields: [
          %{name: "primary", title: "Primary", type: "color"},
          %{name: "secondary", title: "Secondary", type: "color"},
          %{name: "accent", title: "Accent", type: "color"}
        ]
      }
    ]

    # Route through Content.upsert_schema/3 — the SAME write path a real
    # schema registration takes — so every row carries the Default scope ids
    # the scope-filtered /api/schemas read requires (the old raw changeset
    # insert left rows nil-scoped and invisible to assertion #3). The
    # atom-keyed specs are stringified first: upsert_schema injects a string
    # "dataset" key, and a mixed-key map is an Ecto.CastError. Idempotent on
    # (name, dataset).
    #
    # The 9th seed is the CORE `tag` schema (charter D12), read from its one
    # source of truth — TagRegistry.schema_attrs/0 — so this bar and the boot
    # registration can never drift apart.
    stringified = Enum.map(host_specs, &(&1 |> Jason.encode!() |> Jason.decode!()))

    Enum.each(stringified ++ [Barkpark.Content.TagRegistry.schema_attrs()], fn attrs ->
      {:ok, _} = Barkpark.Content.upsert_schema(attrs, dataset, scope)
    end)
  end

  describe "fresh-install invariant" do
    test "supervision tree has no OnixEdit children" do
      children = Supervisor.which_children(Barkpark.Supervisor)

      offenders =
        children
        |> Enum.map(fn {id, _pid, _type, modules} -> {id, modules} end)
        |> Enum.filter(fn {id, modules} ->
          token_match?(id) or Enum.any?(List.wrap(modules), &token_match?/1)
        end)

      assert offenders == [],
             "supervision tree contains plugin children: #{inspect(offenders)}"
    end

    test "GET /studio/production renders 200 with Structure marker (following the scoped-shell redirect)" do
      conn = get_following_redirects("/studio/production")
      body = html_response(conn, 200)

      assert body =~ "Structure",
             "expected nav marker \"Structure\" in Studio HTML, got body of #{byte_size(body)} bytes"
    end

    test "GET /api/schemas returns exactly the 6 PUBLIC seed schema names" do
      conn = build_conn() |> get("/api/schemas")
      body = json_response(conn, 200)

      schema_names =
        body
        |> extract_schema_names()
        |> Enum.sort()

      expected = Enum.sort(@expected_seed_schemas)

      assert schema_names == expected,
             "expected exactly #{inspect(expected)}, got #{inspect(schema_names)}"
    end

    test "Studio HTML contains no plugin-specific tokens" do
      conn = get_following_redirects("/studio/production")
      body = html_response(conn, 200)

      for token <- ["OnixEdit", "Bokbasen", "book"] do
        refute body =~ token,
               "Studio HTML must not contain plugin token #{inspect(token)}"
      end
    end

    # ── Content graph CORE-mount kill-switch guard (Goal ges/graph-edge-seam,
    # FIX 1) ───────────────────────────────────────────────────────────────────
    #
    # The /v1/graph/* HTTP surface and the graph.* CLI verbs were RELOCATED out
    # of the disable-able Tasks plugin into CORE (router.ex `scope "/v1" …
    # get("/graph/…")` + Capabilities.core_commands/0) because the content graph
    # roots on ANY content doc, not just tasks. They MUST therefore survive the
    # documented `config :barkpark, :plugins, []` kill switch this case engages.
    #
    # This is the ONLY context that exercises the graph surface with plugins []:
    # graph_controller_test runs under default ConnCase config (Tasks loaded from
    # disk), and plugin_routes_test only asserts Registry.collect_routes/1 == [].
    # Here we make a REAL HTTP request through the booted :plugins [] endpoint AND
    # read the read-tier manifest directly — the two halves of "still works
    # end-to-end with all plugins off".
    test "GET /v1/graph/<id> is NOT 404 under :plugins [] (core route survives the kill switch)" do
      # Seed a graph root under the Default scope the :api pipeline's
      # AssignDefaultScope plug resolves for a flat /v1/graph request. The `post`
      # schema is one of the 8 host seeds reseeded in setup_all, so a non-task
      # content doc proves the route roots on ANY type (gap #4).
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]
      doc_id = "graph-killswitch-#{System.unique_integer([:positive])}"

      {:ok, _doc} =
        Barkpark.Content.create_document(
          "post",
          %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
          "production",
          scope
        )

      # The root MUST be published: resolve_graph_root only matches published
      # rows at the default perspective (draft-only id => 404, the sealed graph
      # draft-title leak). A draft fixture here would 404 and misread as "route
      # not core-mounted".
      {:ok, _pub} = Barkpark.Content.publish_document(doc_id, "post", "production", scope)

      raw_token = "barkpark-plugin-free-graph-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Barkpark.Auth.create_token(raw_token, "plugin-free-graph", "test", [
          "read",
          "write",
          "admin"
        ])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_token)
        |> get("/v1/graph/#{doc_id}")

      # The CARDINAL assertion: a CORE-mounted route resolves even with plugins
      # []. If these routes had stayed in the Tasks plugin, the request would 404
      # here (Registry.collect_routes/1 == [] under the kill switch).
      refute conn.status == 404,
             "GET /v1/graph/:id 404ed under :plugins [] — the route is NOT core-mounted"

      assert conn.status == 200
    end

    test "read-tier manifest lists the graph.* verbs under :plugins []" do
      manifest = Barkpark.Plugins.Capabilities.manifest("read")

      command_ids =
        manifest
        |> Map.get("commands", [])
        |> Enum.map(&Map.get(&1, "id"))

      for id <- ["graph.show", "graph.orphans", "graph.dangling"] do
        assert id in command_ids,
               "expected core verb #{inspect(id)} in the read-tier manifest under :plugins [], " <>
                 "got #{inspect(command_ids)}"
      end

      # And the `graph` noun survives (a noun is kept only when >= 1 of its
      # commands is visible — proving the verbs are CORE, not plugin-stamped).
      noun_names = manifest |> Map.get("nouns", []) |> Enum.map(&Map.get(&1, "name"))

      assert "graph" in noun_names,
             "expected the core `graph` noun in the read-tier manifest under :plugins []"
    end

    # ── Authoring-excellence publish wall under :plugins [] (charter D12) ─────
    #
    # The wall is CORE (lifecycle.ex), not a before_publish hook — hooks are
    # plugin-droppable, so a plugin-carried wall would silently vanish under
    # the kill switch and this "plugins-off" proof would be vacuous. Here a
    # publish whose weighted tags[].tag is unregistered must STILL come back
    # 422 `unknown_tag` over real HTTP with every plugin off. (The unlabeled-
    # publish arm joins this test when the LabelSpine mount ships — S2 of the
    # same wave.)
    test "publish with an unregistered tag is still 422 unknown_tag under :plugins []" do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]
      doc_id = "wall-killswitch-#{System.unique_integer([:positive])}"
      bogus_tag = "never-registered-#{System.unique_integer([:positive])}"

      {:ok, _draft} =
        Barkpark.Content.create_document(
          "post",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{
              "tags" => [
                %{"tag" => bogus_tag, "strength" => 80, "rationale" => "kill-switch probe"}
              ]
            }
          },
          "production",
          scope
        )

      raw_token = "barkpark-plugin-free-wall-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Barkpark.Auth.create_token(raw_token, "plugin-free-wall", "test", ["read", "write"])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/data/mutate/production",
          Jason.encode!(%{"mutations" => [%{"publish" => %{"id" => doc_id, "type" => "post"}}]})
        )

      body = json_response(conn, 422)

      assert body["error"]["code"] == "unknown_tag",
             "expected the core wall's unknown_tag envelope under :plugins [], got #{inspect(body)}"

      assert bogus_tag in body["error"]["details"]["unknown"]
    end

    # ── Tier 5: host code couples to a REMOVABLE plugin only within the
    #    reviewed allowlist (broadened from the OnixEdit-only grep) ───────────
    #
    # NAMED FAILURE MODE (scar: guard-that-doesn't-guard / vacuous green). The
    # prior tier-5 checked ONE plugin (OnixEdit), so a NEW unconditional
    # core→removable-plugin reach — e.g. core calling `Github.Link` on a path
    # that runs with Github disabled — shipped GREEN: the grep never saw it,
    # and the monorepo keeps the module compiled so no UndefinedFunctionError
    # surfaces at runtime to catch it.
    #
    # This sweep covers EVERY registered (== removable) plugin namespace,
    # derived from priv/plugins/*/plugin.json so a newly added plugin is
    # covered automatically. It uses AST detection of real module references,
    # NOT text grep: a mention of a plugin in a `@moduledoc` or comment is not
    # a coupling and must not count (grep matched prose — e.g. Pulse/Quiz are
    # named ONLY in docstrings and correctly do not appear here).
    #
    # The detected coupling set must EQUAL @sanctioned_host_plugin_coupling.
    test "host code couples to removable plugins only within the reviewed allowlist" do
      detected = detect_host_plugin_couplings()
      allowed = MapSet.new(@sanctioned_host_plugin_coupling)

      new_couplings = MapSet.difference(detected, allowed) |> Enum.sort()
      stale_entries = MapSet.difference(allowed, detected) |> Enum.sort()

      assert new_couplings == [],
             """
             NEW host→removable-plugin coupling outside the allowlist \
             (fresh-install invariant, plugin.ex §Fresh-install invariant):
               #{format_couplings(new_couplings)}
             If this coupling is legitimate — host-owned Studio UI, always-present \
             core-static runtime, or a host module backing a plugin's \
             register_routes/1 surface — add it to \
             @sanctioned_host_plugin_coupling under the matching group WITH a \
             justification. If it is an accidental core→plugin reach on a path \
             that runs while the plugin is disabled, that is exactly the bug \
             this guard exists to catch — remove the reach.
             """

      assert stale_entries == [],
             """
             Stale @sanctioned_host_plugin_coupling entries — no longer present \
             in host code:
               #{format_couplings(stale_entries)}
             Remove them so the allowlist stays an accurate map of real coupling.
             """
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # The flat legacy `/studio/:dataset` path now 302s to the canonical scoped
  # shell (`/w/default/p/default/d/:dataset/studio`). The invariant under test
  # is unchanged — Studio must RENDER with plugins off — so follow the
  # redirect chain (bounded) and assert on the shell's HTML.
  defp get_following_redirects(path, hops \\ 3)

  defp get_following_redirects(path, 0) do
    raise "studio redirect chain did not terminate within 3 hops (last: #{inspect(path)})"
  end

  defp get_following_redirects(path, hops) do
    conn = build_conn() |> get(path)

    if conn.status in [301, 302] do
      [location] = get_resp_header(conn, "location")
      get_following_redirects(location, hops - 1)
    else
      conn
    end
  end

  # The legacy `/api/schemas` endpoint (`LegacyController.schemas/2`)
  # returns a bare JSON array of `%{"name" => ...}` maps. The newer
  # `/v1/schemas/:dataset` returns an envelope `%{"schemas" => [...]}`.
  # Accept both shapes so a future endpoint flip doesn't silently
  # break the regression bar.
  defp extract_schema_names(body) when is_list(body) do
    Enum.map(body, fn
      %{"name" => name} -> name
      other -> raise "unexpected schema entry shape: #{inspect(other)}"
    end)
  end

  defp extract_schema_names(%{"schemas" => list}) when is_list(list) do
    Enum.map(list, fn
      %{"name" => name} -> name
      other -> raise "unexpected schema entry shape: #{inspect(other)}"
    end)
  end

  defp extract_schema_names(other) do
    raise "unexpected /api/schemas response shape: #{inspect(other)}"
  end

  defp token_match?(term) do
    s = term |> inspect() |> to_string()
    String.contains?(s, "OnixEdit") or String.contains?(s, "Bokbasen")
  end

  # ── Tier-5 sweep: AST detection of host→removable-plugin coupling ─────────

  # Every registered plugin is REMOVABLE (`config :barkpark, :plugins, []`
  # unloads it). Deriving the sweep list from the manifests on disk means a
  # newly added plugin is covered automatically — the OnixEdit-only gap that
  # made this guard vacuous cannot recur. Returns each namespace as its atom
  # parts, e.g. `[:Barkpark, :Plugins, :Sheets]`. (Indx is deliberately NOT
  # here: it is not a registered plugin — no priv/plugins/indx — it is
  # declared core-static in application.ex and is always present, so naming it
  # never breaks the fresh-install invariant.)
  defp removable_plugin_module_parts do
    "priv/plugins/*/plugin.json"
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("module")
      |> String.split(".")
      |> Enum.map(&String.to_atom/1)
    end)
  end

  # Set of `{plugin_module_string, host_file}` couplings — a real code
  # reference (compile-time `__aliases__` node), not a docstring/comment
  # mention. Files under `lib/barkpark/plugins/` are the plugins' own tree and
  # excluded; only HOST code is swept.
  defp detect_host_plugin_couplings do
    removable = removable_plugin_module_parts()

    host_files =
      ["lib/barkpark", "lib/barkpark_web"]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.reject(&String.contains?(&1, "/plugins/"))

    for path <- host_files,
        module <- file_plugin_refs(path, removable),
        into: MapSet.new() do
      {module, path}
    end
  end

  # Real plugin-namespace references in one file. Parses to AST (so text inside
  # strings/`@moduledoc`/comments is never matched) and collects every
  # `__aliases__` whose leading atoms are one of the removable namespaces —
  # `Barkpark.Plugins.Sheets`, `...Sheets.Engine`, `...Sheets.unquote(x)` all
  # fold to the top namespace `"Barkpark.Plugins.Sheets"`.
  defp file_plugin_refs(path, removable) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, parts} = node, acc when is_list(parts) ->
          case Enum.find(removable, fn ns -> Enum.take(parts, length(ns)) == ns end) do
            nil -> {node, acc}
            ns -> {node, [Enum.join(ns, ".") | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(refs)
  end

  defp format_couplings([]), do: "(none)"

  defp format_couplings(pairs) do
    pairs
    |> Enum.map(fn {module, file} -> "  - #{module}  ←  #{file}" end)
    |> Enum.join("\n")
  end
end
