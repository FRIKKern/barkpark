defmodule Barkpark.PluginFreeBootTest do
  @moduledoc """
  Goal barkpark-G1 — regression bar for the fresh-install invariant.

  Barkpark must boot, serve Studio, and serve `/api/schemas` with no plugins
  loaded. This case stops `:barkpark`, sets `:plugins` to `[]`, restarts the
  app, and asserts a 5-tier set of invariants over the live system:

    1. The supervision tree has no `Barkpark.Plugins.OnixEdit.*` children.
    2. `GET /studio/production` returns 200 with the `"Structure"` marker.
    3. `GET /api/schemas` returns exactly the 8 seed schema names.
    4. Studio HTML contains no plugin-specific tokens
       (`OnixEdit`, `Bokbasen`, `book`).
    5. Host code under `lib/barkpark` + `lib/barkpark_web` does not
       reference `Barkpark.Plugins.OnixEdit` by name (paths under
       `plugins/onixedit/` excluded).

  Tagged `:boot_test` — excluded from the default `mix test` run. Invoke
  explicitly:

      mix test --only boot_test test/barkpark/plugin_free_boot_test.exs

  The test FAILS until tasks s2 (supervisor pluginification), s3
  (content_renderer split), and s4 (settings_live split) land. That is the
  regression bar — it is the gate that keeps the fresh-install invariant
  from drifting in future PRs.
  """

  use ExUnit.Case, async: false

  @moduletag :boot_test

  import Phoenix.ConnTest
  # `put_req_header/3` (used to attach the Bearer token for the /v1/graph
  # kill-switch request) lives in Plug.Conn, which Phoenix.ConnTest does not
  # re-export — import it directly.
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint BarkparkWeb.Endpoint

  @expected_seed_schemas ~w(post page author category project siteSettings navigation colors)

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
    # the 8 seed names") sees `book` and fails. Q6 of the G1 grill locks
    # the 8-name list — adding a 9th host seed must trigger an explicit
    # assertion update, not silent drift.
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

    Barkpark.Repo.delete_all(Barkpark.Content.SchemaDefinition)
    reseed_host_schemas()

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

  # The 8 host seed schemas, inlined verbatim from `priv/repo/seeds.exs`
  # (the schema half — documents, dev token, codelist seeding skipped).
  #
  # Option B (inline) over option A (Code.eval_file seeds.exs) because
  # seeds.exs is monolithic: schema seeding is followed by 27 document
  # inserts, dev-token creation, plugin-Bootstrap, ONIX codelist seeding,
  # and Thema codelist seeding. The test only queries `/api/schemas` — the
  # extra inserts (especially ~28k codelist rows) are noise. Coupling the
  # test to the canonical 8-schema list IS the regression bar (Q6 locked).
  defp reseed_host_schemas do
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

    # Insert via SchemaDefinition.changeset directly — same path as
    # `priv/repo/seeds.exs`. We deliberately do NOT route through
    # `Content.upsert_schema/2`: that function injects a string
    # `"dataset"` key into the (atom-keyed) attrs, which produces a
    # mixed-key map and Ecto.CastError. The on_conflict: :nothing keeps
    # this idempotent even if a row already exists from a prior reseed.
    Enum.each(host_specs, fn attrs ->
      %Barkpark.Content.SchemaDefinition{}
      |> Barkpark.Content.SchemaDefinition.changeset(attrs)
      |> Barkpark.Repo.insert!(on_conflict: :nothing)
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

    test "GET /studio/production returns 200 with Structure marker" do
      conn = build_conn() |> get("/studio/production")
      body = html_response(conn, 200)

      assert body =~ "Structure",
             "expected nav marker \"Structure\" in Studio HTML, got body of #{byte_size(body)} bytes"
    end

    test "GET /api/schemas returns exactly the 8 seed schema names" do
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
      conn = build_conn() |> get("/studio/production")
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

    test "host code in lib/ does not reference Barkpark.Plugins.OnixEdit by name" do
      api_root = File.cwd!()
      paths = ["lib/barkpark", "lib/barkpark_web"]

      {output, _exit_code} =
        System.cmd(
          "grep",
          ["-r", "-l", "Barkpark.Plugins.OnixEdit" | paths],
          cd: api_root,
          stderr_to_stdout: true
        )

      offenders =
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&plugin_internal_path?/1)

      assert offenders == [],
             "host code references Barkpark.Plugins.OnixEdit: #{inspect(offenders)}"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

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

  # Files inside the plugin's own directory are allowed to mention
  # `Barkpark.Plugins.OnixEdit` — the violation is host code (anything
  # OUTSIDE that subtree) reaching for the plugin module by name.
  defp plugin_internal_path?(path) do
    String.contains?(path, "plugins/onixedit") or String.contains?(path, "Plugins/OnixEdit")
  end
end
