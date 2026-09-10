defmodule BarkparkWeb.Studio.StudioTenantScopeReadsTest do
  @moduledoc """
  task-be3b3aa6da5df3a2 — the Studio reads that dropped the scope the line
  above them had already computed.

  The row filed SIX instances. Re-censused on origin/main before any fix, THREE
  of them still existed (`get_schema/2`, `get_paper/2` and the hand-rolled
  `build_scope_opts/2` copy had already been closed by earlier waves). This file
  proves the surviving three, and — because a fixed call site is invisible to a
  test once it is fixed — installs the SCAN that makes the whole class visible:
  a source guard over `api/lib/barkpark_web/live/studio` that names any read
  reaching for the short arity, with a POSITIVE CONTROL so an empty population
  can never pass it vacuously.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components
  alias BarkparkWeb.Studio.StudioLive.Handlers.Airdrop
  alias BarkparkWeb.Studio.StudioLive.Handlers.Secondary

  # ── instance 3 — the sidebar Relations pane resolves a reference title ──────
  #
  # `Content.reference_title/4` with NO `workspace_id` runs
  # `scope_to_workspace_or_global(nil, nil)`, whose nil arm returns the query
  # UNTOUCHED — every tenant's rows. Two workspaces holding the SAME `doc_id`
  # therefore collapse onto one row, and the sidebar prints whichever the
  # database hands back first. The body of the SAME paper resolves the SAME
  # reference 4-arity WITH scope (shared/paper.ex `paper_stream_items/3`), so
  # this is a divergence inside one screen, not a missing feature.
  describe "the sidebar Relations pane is bound to the caller's tenant" do
    setup do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      {:ok, _a} =
        create_document_in!(ws_a, proj_a, "post", %{
          "doc_id" => "intro",
          "title" => "WORKSPACE A INTRO"
        })

      {:ok, _b} =
        create_document_in!(ws_b, proj_b, "post", %{
          "doc_id" => "intro",
          "title" => "WORKSPACE B INTRO"
        })

      %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
    end

    defp sidebar_html(scope) do
      render_component(&Components.paper_metadata_sidebar/1, %{
        paper_doc: %{
          doc_id: "my-paper",
          title: "My Paper",
          status: "draft",
          content: %{
            "blocks" => [
              %{
                "type" => "field-reference",
                "value" => "intro",
                "refType" => "post",
                "label" => "Intro"
              }
            ]
          }
        },
        dataset: "test",
        scope: scope,
        panel_open: true,
        collapsed: MapSet.new(),
        slug_draft: nil,
        slug_feedback: nil,
        workspace_label: nil
      })
    end

    test "workspace B's sidebar shows B's title and NEVER A's", %{ws_b: ws_b, proj_b: proj_b} do
      html = sidebar_html(workspace_id: ws_b.id, project_id: proj_b.id)

      assert html =~ "WORKSPACE B INTRO"

      refute html =~ "WORKSPACE A INTRO",
             "the Relations pane bound another workspace's SchemaDefinition-era row: " <>
               "reference_title dropped the caller's workspace_id"
    end

    test "workspace A's sidebar shows A's title and NEVER B's", %{ws_a: ws_a, proj_a: proj_a} do
      html = sidebar_html(workspace_id: ws_a.id, project_id: proj_a.id)

      assert html =~ "WORKSPACE A INTRO"
      refute html =~ "WORKSPACE B INTRO"
    end
  end

  # ── criterion 3 — THE SCHEMA CASE, two workspaces, one type name ────────────
  #
  # The row's instance 1 (`Content.get_schema(type, dataset)` beside a scoped
  # `fetch_doc_with_draft` in `handlers/secondary.ex`) is GONE from origin/main:
  # that read is now `Content.resolve_schema(type, dataset,
  # ScopeHelpers.scope_opts(socket))`. A fixed call site is invisible to a test
  # once it is fixed, so this test does not assert the SHAPE of the call — it
  # asserts the BEHAVIOUR the shape buys, over the exact fixture the row
  # describes, at the exact Studio read instance 1 named. Drop the scope
  # argument back off `select_secondary/2` and it goes red (proof in the PR).
  #
  # THE MECHANISM (`content/schema.ex get_schema/3`): with `workspace_id` nil
  # the query runs `scope_to_workspace_or_global(nil, nil)` — the nil arm
  # returns the query UNTOUCHED, every tenant's rows — then
  # `order_by(asc_nulls_last: dataset_id) |> limit(1)`. Two same-named rows
  # therefore collapse to whichever the database hands back first, and this
  # tenant's document renders through the OTHER tenant's field set, visibility
  # flags, list_preview and desk_groups.
  #
  # THE DATASET LEG (the row's METHOD NOTE, checked first): both schema rows are
  # written with a nil `dataset_id` and the dataset STRING "test", so
  # `scope_schema_to_dataset/3`'s `is_nil(s.dataset_id) and s.dataset == ^dataset`
  # arm admits BOTH regardless of what `Content.resolve_read_dataset_id/2`
  # resolves for the seeded Default project. The dataset leaf cannot silently
  # fence this one — the workspace filter is the only thing standing between the
  # two rows, which is what makes the red proof meaningful.
  describe "the Studio secondary pane binds the caller's OWN SchemaDefinition" do
    alias Barkpark.Content.SchemaDefinition

    setup do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      type = "post#{System.unique_integer([:positive])}"

      # A REAL `datasets` row per project, both slugged "test". The nil-dataset_id
      # shape is NOT available here: `schema_definitions_name_dataset_null_dataset_id_index`
      # is a UNIQUE index on (name, dataset) WHERE dataset_id IS NULL, so the
      # database itself refuses two same-named legacy rows — a fence worth
      # recording, and the reason each row below carries a dataset_id.
      {:ok, ds_a} = Barkpark.Tenancy.get_or_create_dataset(proj_a, "test")
      {:ok, ds_b} = Barkpark.Tenancy.get_or_create_dataset(proj_b, "test")

      {:ok, _schema_a} = seed_schema!(type, ws_a, proj_a, ds_a, "WORKSPACE A SCHEMA")
      {:ok, _schema_b} = seed_schema!(type, ws_b, proj_b, ds_b, "WORKSPACE B SCHEMA")

      {:ok, doc_b} =
        create_document_in!(ws_b, proj_b, type, %{
          "doc_id" => "shared-id",
          "title" => "B doc"
        })

      %{ws_b: ws_b, proj_b: proj_b, type: type, doc_b: doc_b}
    end

    defp seed_schema!(name, ws, proj, ds, title) do
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        name: name,
        title: title,
        dataset: "test",
        dataset_id: ds.id,
        workspace_id: ws.id,
        project_id: proj.id,
        fields: [%{"name" => title_field(title), "type" => "string"}]
      })
      |> Barkpark.Repo.insert()
    end

    defp title_field("WORKSPACE A SCHEMA"), do: "a_only_field"
    defp title_field(_), do: "b_only_field"

    defp secondary_socket(ws, proj, type) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_workspace: ws,
          current_project: proj,
          dataset: "test",
          editor_type: type,
          secondary_doc: nil,
          secondary_schema: nil,
          secondary_type: nil,
          show_secondary_picker: true,
          secondary_search: "",
          flash: %{}
        }
      }
    end

    test "workspace B's secondary pane resolves B's schema, never A's", %{
      ws_b: ws_b,
      proj_b: proj_b,
      type: type
    } do
      socket = secondary_socket(ws_b, proj_b, type)

      {:noreply, socket} = Secondary.select_secondary(%{"id" => "shared-id"}, socket)

      schema = socket.assigns.secondary_schema

      assert schema,
             "the secondary pane resolved NO schema — the fixture, not the fence, is wrong"

      assert schema.title == "WORKSPACE B SCHEMA",
             "the Studio bound workspace A's SchemaDefinition to workspace B's document " <>
               "(got #{inspect(schema.title)}) — the schema read dropped the caller's workspace_id"

      assert schema.workspace_id == ws_b.id

      assert Enum.map(schema.fields, & &1["name"]) == ["b_only_field"],
             "the field set came from the other tenant's schema: #{inspect(schema.fields)}"
    end
  end

  # ── instance 5 — airdrop-suggest fences the PRINCIPAL, not just the tenant ──
  #
  # Both siblings in the same module (`airdrop_open/2`, `airdrop_create/2`) open
  # with an `is_nil(principal)` arm. `airdrop_suggest/2` opened only with
  # `is_nil(ws)`. `airdrop-suggest` is absent from `@readonly_events`, which
  # halts share/grant sockets — but `:anonymous_default` attaches NO gate at all
  # (live_scope.ex), so under BARKPARK_PUBLIC_DEMO_STUDIO an anonymous
  # Default-workspace viewer could prefix-enumerate member emails.
  describe "airdrop_suggest/2 principal fence" do
    test "a socket with a workspace but NO principal suggests nothing" do
      ws = create_workspace!()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_workspace: ws,
          current_user: nil,
          current_token: nil,
          airdrop_suggestions: [:sentinel]
        }
      }

      {:noreply, socket} = Airdrop.airdrop_suggest(%{"grantee_email" => "a"}, socket)

      assert socket.assigns.airdrop_suggestions == [],
             "a principal-less socket reached Accounts.search_by_email_prefix/2"
    end
  end

  # ── instance 6 — the GLOBAL document stream is filtered by tenant ───────────
  #
  # `Content.Broadcast` fires `documents:<dataset>` UNCONDITIONALLY for every
  # tenant while the workspace-keyed twin `documents:ws:<id>:<dataset>` is
  # conditional on `doc.workspace_id`. A consumer that joins the global topic
  # therefore sees EVERY workspace's mutations. The payload does carry
  # `workspace_id`, so the fence can live entirely on the consumer side: the
  # topic string is the broadcaster's to change, the FILTER is ours.
  describe "own_tenant?/2 — the global-stream tenant filter" do
    alias BarkparkWeb.Studio.StudioLive.Shared

    test "a message from another workspace is refused" do
      refute Shared.own_tenant?(%{workspace_id: "ws-other"}, "ws-mine")
    end

    test "a message from our own workspace is admitted" do
      assert Shared.own_tenant?(%{workspace_id: "ws-mine"}, "ws-mine")
    end

    test "a SHARED-layer message (no workspace) is admitted to any tenant" do
      assert Shared.own_tenant?(%{workspace_id: nil}, "ws-mine")
      assert Shared.own_tenant?(%{}, "ws-mine")
    end

    test "an unresolved socket (no workspace) admits ONLY the shared layer" do
      assert Shared.own_tenant?(%{workspace_id: nil}, nil)
      refute Shared.own_tenant?(%{workspace_id: "ws-other"}, nil)
    end
  end

  # ── criterion 2 — the guard that would have caught the arity shortfalls ─────
  #
  # The row asks for a `@canonical capability:` marker on the resolver whose
  # 2-arity form drops the workspace, "or an equivalent guard". The marker lives
  # in `api/lib/barkpark/content/schema.ex`, outside this change's fence — and a
  # marker is documentation: it is READ by a human who already went looking.
  # This is the equivalent guard, and it is stronger: it FAILS THE BUILD naming
  # the file and line of any Studio read that reaches for the short arity.
  #
  # THE POSITIVE CONTROL IS THE POINT. A scanner over a population that happens
  # to be empty passes for the wrong reason forever. `short_arity_hits/1` is run
  # first over a PLANTED specimen; if the scan cannot see the specimen the test
  # fails before it ever looks at the real tree.
  describe "no Studio read reaches for the scope-dropping short arity" do
    @studio_root "lib/barkpark_web/live/studio"

    # Each entry: {label, regex matching the SHORT (scope-dropping) arity}.
    # Written as "call( a, b )" with NO further argument before the closing
    # paren — the 4-arity/3-arity scoped forms carry one more argument and do
    # not match.
    @short_arity_shapes [
      {"Content.get_schema/2", ~r/get_schema\(\s*[^,()\n]+,\s*[^,()\n]+\)/},
      {"Content.get_paper/2", ~r/get_paper\(\s*[^,()\n]+,\s*[^,()\n]+\)/},
      {"Content.reference_title/3",
       ~r/reference_title\(\s*[^,()\n]+,\s*[^,()\n]+,\s*[^,()\n]+\)/},
      {"Content.get_document/3", ~r/get_document\(\s*[^,()\n]+,\s*[^,()\n]+,\s*[^,()\n]+\)/}
    ]

    defp short_arity_hits(lines_by_file) do
      for {file, lines} <- lines_by_file,
          {line, idx} <- Enum.with_index(lines, 1),
          {label, re} <- @short_arity_shapes,
          Regex.match?(re, line),
          do: "#{file}:#{idx} — #{label}: #{String.trim(line)}"
    end

    test "POSITIVE CONTROL: the scan sees a planted specimen" do
      planted = %{
        "planted.ex" => [
          "    Content.get_schema(type, dataset)",
          "    Content.get_paper(slug, socket.assigns.dataset)",
          "    Content.reference_title(rel.id, rel.ref_type, assigns.dataset)",
          "    Content.get_document(doc_id, type, dataset)"
        ]
      }

      hits = short_arity_hits(planted)

      assert length(hits) == 4,
             "the scan is BLIND — it saw #{length(hits)} of 4 planted specimens: #{inspect(hits)}"
    end

    test "NEGATIVE CONTROL: the scoped long arities do not match" do
      scoped = %{
        "scoped.ex" => [
          "    Content.get_schema(type, dataset, scope)",
          "    Content.get_paper(slug, dataset, ScopeHelpers.scope_opts(socket))",
          "    Content.reference_title(value, ref_type, dataset, scope)",
          "    Content.get_document(doc_id, type, dataset, opts)"
        ]
      }

      assert short_arity_hits(scoped) == []
    end

    test "the real Studio tree is clean" do
      files =
        Path.wildcard(Path.join(@studio_root, "**/*.ex")) ++
          Path.wildcard(Path.join(@studio_root, "**/*.heex"))

      # The population must be non-empty, or "clean" means "unmeasured".
      assert length(files) > 10,
             "expected the Studio LiveView tree at #{@studio_root}, found #{length(files)} files"

      lines_by_file =
        Map.new(files, fn f -> {f, f |> File.read!() |> String.split("\n")} end)

      hits = short_arity_hits(lines_by_file)

      assert hits == [],
             "a Studio read reaches for the scope-dropping short arity:\n" <>
               Enum.join(hits, "\n")
    end
  end
end
