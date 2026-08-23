defmodule BarkparkWeb.BulldocsLiveTest do
  @moduledoc """
  Gate-A surviving-sentinel test for the convergence MVP (masterplan Fig 6).

  Proves the "no reload" property: a paper renders on mount, and a broadcast
  of updated HTML re-assigns `@html` and is patched into the DOM **without
  remounting**. The proof is two-pronged:

    1. PID identity — the LiveView process pid is identical before and after
       the broadcast (a remount / push_navigate would spawn a new process).
    2. Sentinel survival — `#paper-sentinel`, rendered once at mount OUTSIDE
       the re-assigned container, is still present after the update (a teardown
       would remove it).

  If LiveView were tearing down + re-rendering on each update (the old
  goto-reload behaviour the masterplan replaces), the pid would change and the
  sentinel would be re-created from scratch — the assertions below would fail.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Events
  alias Barkpark.Repo

  @slug "2026-05-23-convergence-demo"

  defp seed_paper(html) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          body_html: html,
          event_type: "plan-written"
        })
      )

    paper
  end

  describe "mount + live update (no reload)" do
    test "renders the seeded body HTML on mount", %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>Hello convergence</h1></section>))

      {:ok, _view, html} = live(conn, "/papers/#{@slug}")

      assert html =~ "Hello convergence"
      assert html =~ ~s(id="block-1")
      # The sentinel element is present at mount.
      assert html =~ ~s(id="paper-sentinel")
    end

    test "broadcast re-assigns @html; same pid + sentinel survive (no remount)",
         %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>First</h1></section>))

      {:ok, view, html} = live(conn, "/papers/#{@slug}")

      # Pre-update state: original block present, the extra block is NOT.
      assert html =~ "First"
      assert html =~ ~s(id="block-1")
      refute html =~ ~s(id="block-2")
      assert html =~ ~s(id="paper-sentinel")

      pid_before = view.pid

      # Broadcast an UPDATED HTML carrying one extra block. This goes through
      # the real Content/PubSub spine: upsert_paper persists + broadcasts on
      # the per-doc topic the LiveView subscribed to at mount.
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @slug,
            body_html:
              ~s(<section id="block-1"><h1>First</h1></section>) <>
                ~s(<section id="block-2"><p>Second block streamed in</p></section>)
          })
        )

      # Pull the post-update DOM. render/1 reflects assigns after handle_info.
      updated = render(view)

      # The new block now renders...
      assert updated =~ ~s(id="block-2")
      assert updated =~ "Second block streamed in"
      # ...alongside the original (diffed in place, not replaced).
      assert updated =~ ~s(id="block-1")
      assert updated =~ "First"

      # SENTINEL 1 — same process: no remount, no push_navigate/redirect.
      assert view.pid == pid_before
      assert Process.alive?(view.pid)

      # SENTINEL 2 — the mount-time marker survived the update; it was diffed,
      # not torn down and rebuilt.
      assert updated =~ ~s(id="paper-sentinel")
      # The marker still carries its mount-time data-slug (unchanged identity).
      assert updated =~ ~s(data-slug="#{@slug}")
    end

    test "returns an explicit 404 when no published paper is stored for the slug", %{conn: conn} do
      assert_raise BarkparkWeb.BulldocsLive.NotFound, fn ->
        live(conn, "/papers/never-saved")
      end
    end

    test "renders a historical paper whose blocks exist only under content.body", %{conn: conn} do
      slug = "2026-07-16-nested-body-reader"

      blocks = [
        %{
          "id" => "nested-body",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Nested body blocks are visible."}]
        }
      ]

      {:ok, paper} =
        Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

      nested_only =
        paper.content
        |> Map.delete("blocks")
        |> Map.delete("body_html")
        |> Map.put("body", %{"blocks" => blocks})

      paper
      |> Ecto.Changeset.change(content: nested_only)
      |> Barkpark.Repo.update!()

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ ~s(data-block-id="nested-body")
      assert html =~ "Nested body blocks are visible."
    end

    test "block-backed public reader rejects a conflicting body_html cache", %{
      conn: conn
    } do
      slug = "2026-07-16-public-block-authority"

      blocks = [
        %{
          "id" => "public-authority",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Public blocks are authoritative."}]
        }
      ]

      {:ok, paper} =
        Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

      stale_content =
        paper.content
        |> Map.put("body_html", "<p>STALE PUBLIC CACHE</p>")
        |> Map.put(
          "body_html_sv",
          Barkpark.PortableDoc.Render.body_html_render_version()
        )

      paper
      |> Ecto.Changeset.change(content: stale_content)
      |> Barkpark.Repo.update!()

      assert_raise BarkparkWeb.BulldocsLive.InvalidSource, fn ->
        live(conn, "/papers/#{slug}")
      end
    end
  end

  describe "backlinks: live related-Paper cards (public flat reader)" do
    @bl_target "2026-06-24-bl-target"
    @bl_source "2026-06-24-bl-source"

    test "renders a related-Paper card for a Paper that references here",
         %{conn: conn} do
      # Target paper (the one being read) — plain HTML body is fine.
      {:ok, _t} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: @bl_target, body_html: "<h1>Target</h1>"})
        )

      # Source paper. A heading block gives it a real title (the engine hydrates
      # the referencer title from the source's documents row).
      {:ok, _s} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @bl_source,
            blocks: [
              %{"id" => "h", "type" => "heading", "level" => 1, "text" => "Source Paper"},
              # A body block: heading-only papers are hollow and refused by the
              # p-quality-gate hollow gate; this test is about edges, not the gate.
              %{
                "id" => "p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      # Materialise the inbound edge in `content_edges` the way the EdgeProjector
      # would on publish — the reader reads the INDEXED engine
      # (`Content.Graph.reverse_referencers/2`), not a block scan, so we seed the
      # edge directly (mirrors graph_test.exs).
      Content.add_edges(
        [%{from_id: @bl_source, to_id: @bl_target, kind: "references"}],
        dataset: Content.paper_default_dataset()
      )

      {:ok, view, html} = live(conn, "/papers/#{@bl_target}")

      assert html =~ "Related papers"
      assert html =~ ~s(data-live="true")
      assert html =~ "Source Paper"
      assert html =~ ~s(href="/papers/#{@bl_source}")

      {:ok, _updated_source} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @bl_source,
            blocks: [
              %{
                "id" => "h",
                "type" => "heading",
                "level" => 1,
                "text" => "Updated Source Paper"
              },
              %{
                "id" => "p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Updated body."}]
              }
            ]
          })
        )

      send(view.pid, {:paper_relations_changed, %{doc_id: @bl_source}})
      refreshed = render(view)

      assert refreshed =~ "Updated Source Paper"
      refute refreshed =~ ">Source Paper<"
    end

    test "omits the section entirely when nothing references the paper", %{conn: conn} do
      {:ok, _t} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: @bl_target, body_html: "<h1>Lonely</h1>"})
        )

      {:ok, _view, html} = live(conn, "/papers/#{@bl_target}")

      assert html =~ "Lonely"
      refute html =~ "Related papers"
      refute html =~ "Driven tasks"
    end
  end

  describe "driven tasks: the expectation reverse view section (lvw-t8)" do
    @dt_paper "2026-07-02-dt-paper"
    @dt_task "2026-07-02-dt-task"

    test "renders a 'Driven tasks' section with the citing task's criteria state",
         %{conn: conn} do
      {:ok, _p} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: @dt_paper, body_html: "<h1>Strategy</h1>"})
        )

      # A REAL published task doc citing the paper via design_doc. The section
      # hydrates the task through Content.get_document, so the doc must exist
      # under the real task schema.
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]
      dataset = Content.paper_default_dataset()

      # E3 tag registry: the fixture weighted tags on the task below must
      # resolve to PUBLISHED type:tag docs in the dataset scope.
      Barkpark.LabelFixtures.register_tags!(dataset)

      for schema_def <- Barkpark.Tasks.schema_definitions(dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
      end

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => @dt_task,
            "title" => "Drive the strategy",
            "content" =>
              Barkpark.LabelFixtures.with_labels(%{
                "kind" => "task",
                "lifecycle_status" => "open",
                "design_doc" => @dt_paper,
                "acceptance_criteria" => [
                  %{"criterion" => "satisfied claim", "met" => true, "evidence" => "PR #42"},
                  %{"criterion" => "open claim", "met" => false}
                ]
              })
          },
          dataset,
          scope
        )

      {:ok, _} = Content.publish_document(@dt_task, "task", dataset, scope)

      # Materialise the inbound design_doc edge the way the EdgeProjector would
      # on publish — the reader reads the INDEXED engine (same seeding
      # convention as the backlinks tests above; the real projector loop is
      # proven in expectations_test.exs / paper_body_edges_test.exs).
      Content.add_edges(
        [%{from_id: @dt_task, to_id: @dt_paper, kind: "design_doc"}],
        dataset: dataset
      )

      {:ok, _view, html} = live(conn, "/papers/#{@dt_paper}")

      assert html =~ "Driven tasks"
      assert html =~ "Drive the strategy"
      assert html =~ "1/2 met"
      assert html =~ "satisfied claim"
      assert html =~ "PR #42"
      assert html =~ "open claim"
    end
  end

  describe "used-by / impact panel: valueref referencers of a canonical value doc (lvw-t3)" do
    @ub_canonical "2026-07-02-ub-canonical"
    @ub_user "2026-07-02-ub-user"
    @ub_hidden "2026-07-02-ub-hidden"

    test "a valueref-kind edge renders under 'Used by'; an out-of-scope referencer is dropped with NO stub and NO aggregate count",
         %{conn: conn} do
      dataset = Content.paper_default_dataset()

      # The canonical value doc being read. Published via the canonical paper
      # write path — the panel reflects the PUBLISHED corpus only (D1): a
      # draft-only referencing paper would have no materialised edge, and its
      # absence is correct v1 behaviour, not a bug.
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @ub_canonical,
            body_html: "<h1>Canonical Value</h1>"
          })
        )

      # In-scope referencer: a published paper whose body valueref-references
      # the canonical doc (the #714 body-walk extractor materialises exactly
      # this row on publish — kind "valueref", plugin_source "bulldocs").
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @ub_user,
            blocks: [
              %{"id" => "h", "type" => "heading", "level" => 1, "text" => "Dependent Paper"},
              # A body block: heading-only papers are hollow and refused by the
              # p-quality-gate hollow gate; this test is about edges, not the gate.
              %{
                "id" => "p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      # Out-of-scope referencer: an owner_scoped published doc owned by a user.
      # The public reader threads NO caller_context, so the graph's hydration
      # fails CLOSED to unowned-only rows (LOW-12/MEDIUM-5) — this source must
      # vanish from the panel entirely.
      Content.upsert_schema(
        %{
          "name" => "hidden_value_user",
          "title" => "Hidden Value User",
          "owner_scoped" => true,
          "fields" => []
        },
        dataset
      )

      owner_ctx = [
        caller_context: Barkpark.Content.CallerContext.from_user(Ecto.UUID.generate(), roles: [])
      ]

      {:ok, _} =
        Content.create_document(
          "hidden_value_user",
          %{"_id" => @ub_hidden, "title" => "Secret Dependent"},
          dataset,
          owner_ctx
        )

      {:ok, _} = Content.publish_document(@ub_hidden, "hidden_value_user", dataset, owner_ctx)

      Content.add_edges(
        [
          %{
            from_id: @ub_user,
            to_id: @ub_canonical,
            kind: "valueref",
            plugin_source: "bulldocs"
          },
          %{
            from_id: @ub_hidden,
            to_id: @ub_canonical,
            kind: "valueref",
            plugin_source: "bulldocs"
          }
        ],
        dataset: dataset
      )

      {:ok, _view, html} = live(conn, "/papers/#{@ub_canonical}")

      # The REAL valueref-kind edge renders in the panel: the referencing paper
      # lists under "Used by" (not under "Related papers" — no non-valueref
      # referencer exists here, so that section is absent entirely).
      assert html =~ "Used by"
      assert html =~ "Dependent Paper"
      assert html =~ ~s(href="/papers/#{@ub_user}")
      refute html =~ "Related papers"

      # Fail-closed (MEDIUM-5): the out-of-scope referencer leaves NO trace —
      # no title, no slug/link, no stub row.
      refute html =~ "Secret Dependent"
      refute html =~ @ub_hidden

      # ...and NO aggregate "K you cannot see" count: the Used-by list carries
      # EXACTLY the one visible row.
      [used_by_section] = Regex.run(~r/<section class="bp-paper-usedby".*?<\/section>/s, html)
      assert length(String.split(used_by_section, "<li", trim: true)) == 2
    end
  end

  describe "Gate-B: multi-block streaming (no reload across a sequence)" do
    @block_slug "2026-05-23-wave4-stream"

    defp seed_block_paper do
      blocks = [
        %{
          "id" => "b-intro",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "First block streamed."}]
        }
      ]

      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @block_slug,
            blocks: blocks,
            event_type: "plan-written"
          })
        )

      paper
    end

    defp append_block_op(id, text) do
      %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    test "mount streams the initial block keyed by its id", %{conn: conn} do
      seed_block_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@block_slug}")

      # Stream container is present and renders the seeded block.
      assert html =~ ~s(phx-update="stream")
      assert html =~ ~s(data-block-id="b-intro")
      assert html =~ "First block streamed."
      assert html =~ ~s(id="paper-sentinel")
    end

    test "a SEQUENCE of appends each appear via the stream; sentinel + prior blocks + pid survive",
         %{conn: conn} do
      seed_block_paper()

      {:ok, view, html} = live(conn, "/papers/#{@block_slug}")
      assert html =~ "First block streamed."
      refute html =~ "data-block-id=\"b-2\""

      pid_before = view.pid

      # Append three blocks in sequence through the real context + PubSub spine.
      # Each apply_block_op renders the fragment, bumps rev, broadcasts a
      # {:paper_block, …} delta the LiveView (subscribed at mount) consumes.
      {:ok, _} =
        Content.apply_paper_block_op(@block_slug, append_block_op("b-2", "Second block."))

      {:ok, _} = Content.apply_paper_block_op(@block_slug, append_block_op("b-3", "Third block."))

      {:ok, _} =
        Content.apply_paper_block_op(@block_slug, append_block_op("b-4", "Fourth block."))

      rendered = render(view)

      # Every new block appears in the DOM, keyed by id, via the stream...
      assert rendered =~ ~s(data-block-id="b-2")
      assert rendered =~ "Second block."
      assert rendered =~ ~s(data-block-id="b-3")
      assert rendered =~ "Third block."
      assert rendered =~ ~s(data-block-id="b-4")
      assert rendered =~ "Fourth block."

      # ...the original block survived (it was never re-rendered)...
      assert rendered =~ ~s(data-block-id="b-intro")
      assert rendered =~ "First block streamed."

      # SENTINEL 1 — same process across the WHOLE sequence: no remount,
      # no push_navigate/redirect at any step = no reload.
      assert view.pid == pid_before
      assert Process.alive?(view.pid)

      # SENTINEL 2 — the mount-time marker survived every delta.
      assert rendered =~ ~s(id="paper-sentinel")
      assert rendered =~ ~s(data-slug="#{@block_slug}")
    end

    test "a patch-block delta patches one block in place; the rest are untouched",
         %{conn: conn} do
      seed_block_paper()

      {:ok, _} =
        Content.apply_paper_block_op(@block_slug, append_block_op("b-2", "Second block."))

      {:ok, view, _html} = live(conn, "/papers/#{@block_slug}")
      pid_before = view.pid

      patch = %{
        "op" => "patch-block",
        "id" => "b-intro",
        "patch" => %{"content" => [%{"type" => "text", "value" => "First block EDITED."}]}
      }

      {:ok, _} = Content.apply_paper_block_op(@block_slug, patch)
      rendered = render(view)

      assert rendered =~ "First block EDITED."
      refute rendered =~ "First block streamed."
      # Sibling block untouched.
      assert rendered =~ "Second block."
      # No remount.
      assert view.pid == pid_before
    end

    test "rev-gap recovery: a delta whose rev skips ahead triggers a full refetch",
         %{conn: conn} do
      seed_block_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@block_slug}")
      pid_before = view.pid

      # Persist two blocks straight into the context (bumps rev), but hand the
      # LiveView a SINGLE delta whose rev is ahead of what it last saw — a
      # simulated dropped frame. The view must refetch the full doc.
      {:ok, _} =
        Content.apply_paper_block_op(@block_slug, append_block_op("b-2", "Recovered B2."))

      {:ok, last} =
        Content.apply_paper_block_op(@block_slug, append_block_op("b-3", "Recovered B3."))

      # Frame with a rev far ahead of the mount rev → gap → refetch path.
      send(
        view.pid,
        {:paper_block,
         %{
           op_kind: "append-block",
           block_id: "b-3",
           fragment_html: "<p>stale fragment ignored</p>",
           position: 2,
           rev: last.rev
         }}
      )

      rendered = render(view)

      # The refetch pulled the true current doc — both persisted blocks present,
      # the stale inline fragment was NOT used.
      assert rendered =~ "Recovered B2."
      assert rendered =~ "Recovered B3."
      refute rendered =~ "stale fragment ignored"
      # Still no remount.
      assert view.pid == pid_before
      assert rendered =~ ~s(id="paper-sentinel")
    end

    test "whole-HTML fallback still works: a :paper_updated broadcast re-assigns",
         %{conn: conn} do
      # An HTML-only paper (no blocks) keeps the Wave-3 re-assign path.
      slug = "wave4-html-fallback"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: slug, body_html: "<p id=\"v1\">v1</p>"})
        )

      {:ok, view, html} = live(conn, "/papers/#{slug}")
      assert html =~ ~s(id="v1")
      refute html =~ ~s(id="v2")
      pid_before = view.pid

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            body_html: "<p id=\"v2\">v2 re-assigned</p>"
          })
        )

      rendered = render(view)
      assert rendered =~ ~s(id="v2")
      assert rendered =~ "v2 re-assigned"
      # No remount on the fallback path either.
      assert view.pid == pid_before
      assert rendered =~ ~s(id="paper-sentinel")
    end

    test "whole-HTML broadcasts are advisory and cannot inject an unvalidated body", %{
      conn: conn
    } do
      slug = "wave4-html-advisory"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            body_html: "<p id=\"stored-safe\">Stored safe body</p>"
          })
        )

      {:ok, view, _html} = live(conn, "/papers/#{slug}")
      send(view.pid, {:paper_updated, %{html: "<script>injected()</script>", rev: 999}})

      rendered = render(view)
      assert rendered =~ "Stored safe body"
      assert rendered =~ ~s(id="stored-safe")
      refute rendered =~ "injected()"
    end

    test "connected refetch exposes an explicit invalid-source state instead of an empty success",
         %{conn: conn} do
      slug = "wave4-invalid-refetch"
      blocks = [%{"id" => "body", "type" => "paragraph", "text" => "Initially valid"}]

      {:ok, paper} =
        Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

      {:ok, view, html} = live(conn, "/papers/#{slug}")
      assert html =~ "Initially valid"

      paper
      |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", "<p>conflict</p>"))
      |> Repo.update!()

      send(view.pid, {:paper_updated, %{html: "<p>conflict</p>", rev: 999}})
      rendered = render(view)

      assert rendered =~ ~s(id="paper-invalid")
      assert rendered =~ ~s(data-source-error="ambiguous_source")
      refute rendered =~ "Initially valid"
      refute rendered =~ "<p>conflict</p>"
    end
  end

  describe "P6.U2: goal-path rail" do
    @rail_slug "2026-05-25-goal-rail-demo"
    @rail_goal "g-test"

    # Seed a paper with a goal_id. upsert_paper with a present event_type
    # creates the paper AND (via U1) one paper_event for the goal. We then add
    # two more events for the same goal directly through the Events context so
    # the rail has a 3-commit lineage.
    defp seed_rail_paper do
      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @rail_slug,
            "style" => "article",
            "goal_id" => @rail_goal,
            "event_type" => "goal-opened",
            "blocks" => [
              %{
                "id" => "r-intro",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Rail demo body."}]
              }
            ]
          })
        )

      # W1.5-C: the rail now scopes events to the paper's OWN workspace, so the
      # follow-up events must carry the paper's resolved scope (upsert_paper
      # Default-stamped the paper above) to appear in the rail — mirroring how a
      # real BulldocsLive write stamps the paper's workspace onto each event.
      scope = %{"workspace_id" => paper.workspace_id, "project_id" => paper.project_id}

      {:ok, _} =
        Events.create_event(
          Map.merge(scope, %{"goal_id" => @rail_goal, "event_type" => "plan-written"})
        )

      {:ok, _} =
        Events.create_event(
          Map.merge(scope, %{"goal_id" => @rail_goal, "event_type" => "goal-snapshot"})
        )

      paper
    end

    test "renders the rail with a linear gitGraph commit per event", %{conn: conn} do
      seed_rail_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@rail_slug}")

      # The rail element is present.
      assert html =~ ~s(id="goal-path-rail")
      assert html =~ "Goal path"

      # The gitGraph header + a commit per each of the 3 events, under the hook.
      # The hook lives on #goal-path-graph which wraps the gitGraph <pre>.
      assert html =~ ~s(phx-hook="PaperMermaid")
      assert html =~ ~s(id="goal-path-graph")
      assert html =~ "gitGraph"

      # One unique, index-suffixed commit id per event, in inserted_at order.
      # HEEx auto-escapes the `"` around each id to `&quot;` in the rendered
      # HTML (the browser DOM hands Mermaid the unescaped text) — so match the
      # escaping-agnostic `commit id:` + the bare id text.
      assert html =~ "commit id:"
      assert html =~ "goal-opened-1"
      assert html =~ "plan-written-2"
      assert html =~ "goal-snapshot-3"

      # Exactly three commits emitted (no stray extra commit lines).
      assert length(String.split(html, "commit id:")) - 1 == 3

      # Event types render in the clickable fallback list, with click wiring.
      assert html =~ "goal-opened"
      assert html =~ "plan-written"
      assert html =~ "goal-snapshot"
      assert html =~ ~s(phx-click="rail-select")
    end

    test "rail-select highlights the chosen event row (selection only, no swap)",
         %{conn: conn} do
      seed_rail_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@rail_slug}")

      # Pick the first event row and click it.
      [event_id | _] =
        Events.list_for_goal(@rail_goal) |> Enum.map(& &1.id)

      rendered =
        view
        |> element(~s([phx-value-event-id="#{event_id}"]))
        |> render_click()

      # The selected row carries the highlight class; the article body is
      # untouched (no swap/diff in v1).
      assert rendered =~ "is-selected"
      assert rendered =~ "Rail demo body."
    end

    test "a paper WITHOUT a goal_id renders NO rail", %{conn: conn} do
      slug = "2026-05-25-no-goal-paper"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "style" => "article",
            "body_html" => "<p id=\"no-goal-body\">No goal here.</p>"
          })
        )

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "No goal here."
      # Negative case: no rail element and no emitted gitGraph commits.
      # (The word "gitGraph" alone appears in the layout's CSS comment, so we
      # assert on the rail element + an actual `commit id:` line instead.)
      refute html =~ ~s(id="goal-path-rail")
      refute html =~ "commit id:"
    end
  end

  describe "P6.U3: diff modal" do
    @diff_slug "2026-05-25-diff-modal-demo"
    @diff_goal "g-diff"

    # Seed a paper with a goal_id plus two events whose payload_html differs by
    # one line — so the diff has a stable context line, one removed, one added.
    defp seed_diff_paper do
      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @diff_slug,
            "style" => "article",
            "goal_id" => @diff_goal,
            "body_html" => "<p id=\"diff-body\">Diff demo body.</p>"
          })
        )

      # W1.5-C (same reason as seed_rail_paper above): the rail scopes events to
      # the paper's OWN workspace, so these must carry the paper's resolved scope
      # to appear on it — mirroring how a real BulldocsLive write stamps the
      # paper's workspace onto each event. Without it the paper is Default-stamped
      # while its events are workspace-less, the rail loads EMPTY, and open-diff
      # cannot find the paper's own events.
      scope = %{"workspace_id" => paper.workspace_id, "project_id" => paper.project_id}

      {:ok, a} =
        Events.create_event(
          Map.merge(scope, %{
            "goal_id" => @diff_goal,
            "paper_slug" => @diff_slug,
            "event_type" => "plan-written",
            "payload_html" => "shared line\nORIGINAL middle\ntail line"
          })
        )

      {:ok, b} =
        Events.create_event(
          Map.merge(scope, %{
            "goal_id" => @diff_goal,
            "paper_slug" => @diff_slug,
            "event_type" => "plan-grilled",
            "payload_html" => "shared line\nREVISED middle\ntail line"
          })
        )

      {paper, a, b}
    end

    test "open-diff renders the modal with added/removed lines; close-diff hides it",
         %{conn: conn} do
      {_paper, a, b} = seed_diff_paper()

      {:ok, view, html} = live(conn, "/papers/#{@diff_slug}")

      # Modal is NOT present before any diff is opened.
      refute html =~ ~s(id="bp-diff-modal")

      # Push the open-diff hook event with the two seeded event ids.
      rendered = render_hook(view, "open-diff", %{"from" => a.id, "to" => b.id})

      # The modal renders, titled with both event types...
      assert rendered =~ ~s(id="bp-diff-modal")
      assert rendered =~ "plan-written"
      assert rendered =~ "plan-grilled"

      # ...and shows the diff body: shared context line, removed + added line.
      assert rendered =~ ~s(class="bp-diff")
      assert rendered =~ "shared line"
      assert rendered =~ ~s(bp-diff-del)
      assert rendered =~ "ORIGINAL middle"
      assert rendered =~ ~s(bp-diff-add)
      assert rendered =~ "REVISED middle"

      # Close it via the close button → modal gone.
      closed =
        view
        |> element(~s(button.bp-diff-close))
        |> render_click()

      refute closed =~ ~s(id="bp-diff-modal")
    end

    test "open-diff with a missing event is a no-op (no crash, no modal)",
         %{conn: conn} do
      {_paper, a, _b} = seed_diff_paper()

      {:ok, view, _html} = live(conn, "/papers/#{@diff_slug}")

      missing = Ecto.UUID.generate()
      rendered = render_hook(view, "open-diff", %{"from" => a.id, "to" => missing})

      # No modal, and the LiveView is still alive (the missing event was guarded).
      refute rendered =~ ~s(id="bp-diff-modal")
      assert Process.alive?(view.pid)
    end

    test "open-diff with a malformed (non-UUID) event id is a no-op (no crash)",
         %{conn: conn} do
      {_paper, a, _b} = seed_diff_paper()

      {:ok, view, _html} = live(conn, "/papers/#{@diff_slug}")

      # A client-controlled non-UUID id must not raise Ecto.Query.CastError.
      rendered = render_hook(view, "open-diff", %{"from" => a.id, "to" => "not-a-uuid"})

      refute rendered =~ ~s(id="bp-diff-modal")
      assert Process.alive?(view.pid)
    end
  end

  describe "P6.U5: action buttons (routing Option B — record intent as paper_events)" do
    @action_slug "2026-05-25-action-buttons-demo"
    @action_goal "g-action"

    # Seed an article paper whose originating doc is a /plans/ doc and which
    # carries a goal_id — so the action set is the plan pair (build + grill) and
    # a click can be attributed to the goal.
    defp seed_action_paper do
      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @action_slug,
            "style" => "article",
            "goal_id" => @action_goal,
            "source_doc" => "/plans/2026-05-25-convergence-plan.html",
            "body_html" => "<p id=\"action-body\">Action demo body.</p>"
          })
        )

      paper
    end

    test "a /plans/ paper renders the plan action bar (build + grill)", %{conn: conn} do
      seed_action_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@action_slug}")

      # The bar element + both plan buttons, each wired to "paper-action".
      assert html =~ ~s(id="paper-action-bar")
      assert html =~ "Build this plan"
      assert html =~ "Grill the plan"
      assert html =~ ~s(phx-click="paper-action")
      assert html =~ ~s(phx-value-action="build")
      assert html =~ ~s(phx-value-action="grill")
    end

    test "clicking an action button records an action:<key> paper_events row + acknowledges",
         %{conn: conn} do
      seed_action_paper()

      {:ok, view, _html} = live(conn, "/papers/#{@action_slug}")

      # No action events yet for this goal.
      refute Enum.any?(
               Events.list_for_goal(@action_goal),
               &(&1.event_type == "action:build")
             )

      rendered =
        view
        |> element(~s(button[phx-value-action="build"]))
        |> render_click()

      # The UI acknowledges the click inline.
      assert rendered =~ "Requested: Build this plan"

      # A paper_events row now exists for the goal, typed action:build, with the
      # intent payload — orchestrator-readable + visible in the U2 rail.
      events = Events.list_for_goal(@action_goal)
      build = Enum.find(events, &(&1.event_type == "action:build"))

      assert build
      assert build.paper_slug == @action_slug
      assert build.goal_id == @action_goal
      assert build.branch == "main"
      assert build.payload_html =~ "Action 'build' requested from /papers/#{@action_slug}"
    end

    test "a paper WITHOUT a source_doc renders NO action bar", %{conn: conn} do
      slug = "2026-05-25-no-source-doc-paper"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "style" => "article",
            "body_html" => "<p id=\"no-source-body\">No source doc here.</p>"
          })
        )

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "No source doc here."
      refute html =~ ~s(id="paper-action-bar")
      refute html =~ ~s(phx-click="paper-action")
    end
  end

  describe "P6.U4: Simplify control (routing Option B — record simplify intent + decision as paper_events)" do
    @simplify_slug "2026-05-25-simplify-demo"
    @simplify_goal "g-simplify"

    # Seed a goal-bearing article paper. Simplify applies to ANY paper with a
    # goal_id, independent of source_doc — so we deliberately omit source_doc
    # here (no U5 action bar) to prove Simplify is its own control.
    defp seed_simplify_paper do
      {:ok, paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @simplify_slug,
            "style" => "article",
            "goal_id" => @simplify_goal,
            "body_html" => "<p id=\"simplify-body\">Simplify demo body.</p>"
          })
        )

      paper
    end

    test "a goal-bearing paper renders the Simplify button", %{conn: conn} do
      seed_simplify_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@simplify_slug}")

      assert html =~ ~s(id="paper-simplify")
      assert html =~ "Simplify"
      assert html =~ ~s(phx-click="simplify-request")
      # No request pending yet → no Accept/Reject controls.
      refute html =~ ~s(phx-click="simplify-accept")
      refute html =~ ~s(phx-click="simplify-reject")
    end

    test "clicking Simplify records a simplify-request on simplified-1 + reveals Accept/Reject",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      # No simplify events yet for this paper.
      refute Enum.any?(
               Events.list_for_paper(@simplify_slug),
               &(&1.event_type == "simplify-request")
             )

      rendered =
        view
        |> element(~s(button[phx-click="simplify-request"]))
        |> render_click()

      # A simplify-request row now exists on the first branch.
      events = Events.list_for_paper(@simplify_slug)
      req = Enum.find(events, &(&1.event_type == "simplify-request"))

      assert req
      assert req.branch == "simplified-1"
      assert req.goal_id == @simplify_goal
      assert req.paper_slug == @simplify_slug
      assert req.payload_html =~ "simplified-1"

      # The UI acknowledges + now offers Accept/Reject.
      assert rendered =~ "Simplify requested — simplified-1"
      assert rendered =~ ~s(phx-click="simplify-accept")
      assert rendered =~ ~s(phx-click="simplify-reject")
    end

    test "a second Simplify click increments the branch index to simplified-2",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      view |> element(~s(button[phx-click="simplify-request"])) |> render_click()
      rendered = view |> element(~s(button[phx-click="simplify-request"])) |> render_click()

      branches =
        Events.list_for_paper(@simplify_slug)
        |> Enum.filter(&(&1.event_type == "simplify-request"))
        |> Enum.map(& &1.branch)
        |> Enum.sort()

      assert branches == ["simplified-1", "simplified-2"]
      assert rendered =~ "Simplify requested — simplified-2"
    end

    test "clicking Accept records a simplify-accept event on the pending branch",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      view |> element(~s(button[phx-click="simplify-request"])) |> render_click()
      rendered = view |> element(~s(button[phx-click="simplify-accept"])) |> render_click()

      accept =
        Events.list_for_paper(@simplify_slug)
        |> Enum.find(&(&1.event_type == "simplify-accept"))

      assert accept
      assert accept.branch == "simplified-1"
      assert accept.goal_id == @simplify_goal
      assert accept.paper_slug == @simplify_slug

      # Ack shown + the decision controls retract (pending cleared).
      assert rendered =~ "Accepted simplified-1"
      refute rendered =~ ~s(phx-click="simplify-accept")
    end

    test "clicking Reject records a simplify-reject event on the pending branch",
         %{conn: conn} do
      seed_simplify_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@simplify_slug}")

      view |> element(~s(button[phx-click="simplify-request"])) |> render_click()
      rendered = view |> element(~s(button[phx-click="simplify-reject"])) |> render_click()

      reject =
        Events.list_for_paper(@simplify_slug)
        |> Enum.find(&(&1.event_type == "simplify-reject"))

      assert reject
      assert reject.branch == "simplified-1"
      assert rendered =~ "Rejected simplified-1"
      refute rendered =~ ~s(phx-click="simplify-reject")
    end

    test "a paper WITHOUT a goal_id renders NO Simplify button", %{conn: conn} do
      slug = "2026-05-25-no-goal-simplify-paper"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "style" => "article",
            "body_html" => "<p id=\"no-goal-simplify-body\">No goal, no simplify.</p>"
          })
        )

      {:ok, _view, html} = live(conn, "/papers/#{slug}")

      assert html =~ "No goal, no simplify."
      refute html =~ ~s(id="paper-simplify")
      refute html =~ ~s(phx-click="simplify-request")
    end
  end

  # Crash-class closure (#819): BulldocsLive had 7 handle_event heads and no
  # fall-through, so a stale/forged phx event FunctionClauseError-crashed the
  # reader session. The trailing handle_event/3 catch-all now no-ops it (the
  # handle_info/2 catch-all already existed).
  describe "dispatch fall-through keeps the reader alive" do
    test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>Alive</h1></section>))

      {:ok, view, _html} = live(conn, "/papers/#{@slug}")

      render_hook(view, "totally-unknown-stale-event", %{"leftover" => "true"})

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
    end
  end

  # preview-contract pc-w2: the reader emits the social-share head (og/twitter/
  # JSON-LD) from the paper's preview manifest — in the DEAD (disconnected)
  # render, because crawlers + unfurlers (Slack/Discord/iMessage/LinkedIn) run
  # no JS. We assert against `get/2` (the crawler's view), not the live socket.
  describe "social-share head (og/twitter/JSON-LD)" do
    test "the dead render carries the og/twitter head for a paper", %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>Shareable</h1></section>))

      conn = get(conn, "/papers/#{@slug}")
      html = html_response(conn, 200)
      base = BarkparkWeb.Endpoint.url()

      # A paper's raw type maps to og:type=article (D8), with the canonical,
      # absolutized og:url (D3) present exactly once.
      assert html =~ ~s(<meta property="og:type" content="article")
      assert html =~ ~s(<meta property="og:url" content="#{base}/papers/#{@slug}")
      assert length(String.split(html, ~s(property="og:url"))) - 1 == 1

      # Branded default card at emission (D5) — no featured image on this paper.
      assert html =~ ~s(<meta property="og:image" content="#{base}/images/og-default.jpg")
      assert html =~ ~s(<meta property="og:image:width" content="1200")

      # twitter card, name= discipline.
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")

      # JSON-LD Article for a paper.
      assert html =~ ~s(<script type="application/ld+json">)
      assert html =~ ~s("@type":"Article")

      # The share head sits BEFORE the multi-KB inline <style> blob (Slack reads
      # only the first 32 KB).
      assert byte_index(html, ~s(property="og:image")) < byte_index(html, "<style")
    end

    test "the <title> reflects the paper title, not the hardcoded default", %{conn: conn} do
      # A titled article paper — `derive_title/2` sets the row title from the
      # `role: "title"` block's text (pdd-t4 doctrine).
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: "titled-share-paper",
            blocks: [
              %{"type" => "heading", "role" => "title", "text" => "A Branded Title"},
              %{"type" => "paragraph", "text" => "Body."}
            ]
          })
        )

      conn = get(conn, "/papers/titled-share-paper")
      html = html_response(conn, 200)

      # `<.live_title>` (A7) emits `<title data-default=… data-suffix=…>` so the
      # LiveView reader updates the browser tab when the title changes — assert
      # on the rendered title CONTENT, robust to the tag attributes. The
      # `>…</title>` anchor keeps the refute honest: the default string also
      # appears inside the `data-default`/`data-suffix` attributes.
      assert html =~ "A Branded Title · Barkpark</title>"
      assert html =~ ~s(<meta property="og:title" content="A Branded Title")
      refute html =~ ">Paper · Barkpark</title>"
    end
  end

  describe "field-reference / codelist resolution on the public reader (pbw-w1)" do
    # The anonymous reader mount/refetch wires the SAME `:ref_resolver` /
    # `:codelist_resolver` closures Studio and the body_html cache use, so a
    # `field-reference` block shows the referenced doc's TITLE and a `codelist`
    # block its human LABEL instead of leaking the raw slug/code (live bug:
    # /papers/portabledoc-showcase rendered `terminal-mermaid-diagrams` raw).
    # Tenant scope + published_only flow through unchanged (D2, fail-closed).

    test "a published field-reference renders the referenced doc's TITLE, not the raw id",
         %{conn: conn} do
      {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      dataset = Content.paper_default_dataset()

      # A PUBLISHED referenced doc in the reader's tenant — created THEN
      # published so a real published projection exists (the exact row shape the
      # published_only gate admits: status "published", bare doc_id).
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "pbw-ref-target", "title" => "The Referenced Title"},
          dataset,
          workspace_id: ws.id
        )

      {:ok, _} =
        Content.publish_document("pbw-ref-target", "post", dataset, workspace_id: ws.id)

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: "pbw-ref-paper",
            style: "article",
            blocks: [
              %{"type" => "heading", "role" => "title", "text" => "Reference Host"},
              %{"type" => "paragraph", "text" => "Body copy to clear the hollow gate."},
              %{
                "id" => "the-ref",
                "type" => "field-reference",
                "label" => "Related",
                "value" => "pbw-ref-target"
              }
            ]
          })
        )

      {:ok, _view, html} = live(conn, "/papers/pbw-ref-paper")

      # The referenced doc's TITLE is resolved and rendered…
      assert html =~ "The Referenced Title"
      # …and the raw id never leaks in the field-reference row (regression: the
      # reader used to render the raw slug because it wired no `:ref_resolver`).
      refute html =~ "pbw-ref-target"
    end

    test "a codelist block with a REGISTERED code renders its human LABEL", %{conn: conn} do
      _ = Barkpark.TenancyFixtures.ensure_default_scope!()

      {:ok, _} =
        Barkpark.Content.Codelists.register("onixedit", "pbw:contributor_role", %{
          issue: "1",
          name: "PBW Contributor Role",
          values: [%{code: "A01", translations: [%{language: "eng", label: "By (author)"}]}]
        })

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: "pbw-codelist-paper",
            style: "article",
            blocks: [
              %{"type" => "heading", "role" => "title", "text" => "Codelist Host"},
              %{"type" => "paragraph", "text" => "Body copy to clear the hollow gate."},
              %{
                "id" => "the-code",
                "type" => "codelist",
                "label" => "Role",
                "plugin" => "onixedit",
                "codelistId" => "pbw:contributor_role",
                "value" => "A01"
              }
            ]
          })
        )

      {:ok, _view, html} = live(conn, "/papers/pbw-codelist-paper")

      # The registered code's LABEL renders instead of the raw code.
      assert html =~ "By (author)"
    end

    test "a field-reference to a DRAFT-ONLY doc still renders the raw value (fail-closed)",
         %{conn: conn} do
      {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      dataset = Content.paper_default_dataset()

      # A doc that was NEVER published — only its draft exists. The anonymous
      # reader threads `published_only: true`, so `reference_title` drops the
      # `drafts.` twin and the reference degrades to the raw id: a draft title
      # must NEVER leak on the public surface.
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "pbw-draft-target", "title" => "Secret Draft Title"},
          dataset,
          workspace_id: ws.id
        )

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: "pbw-draft-ref-paper",
            style: "article",
            blocks: [
              %{"type" => "heading", "role" => "title", "text" => "Draft Reference Host"},
              %{"type" => "paragraph", "text" => "Body copy to clear the hollow gate."},
              %{
                "id" => "the-draft-ref",
                "type" => "field-reference",
                "label" => "Related",
                "value" => "pbw-draft-target"
              }
            ]
          })
        )

      {:ok, _view, html} = live(conn, "/papers/pbw-draft-ref-paper")

      # The raw id renders (the reference is unresolved) and the draft title is
      # nowhere on the page.
      assert html =~ "pbw-draft-target"
      refute html =~ "Secret Draft Title"
    end
  end

  # Byte offset of the first occurrence of `needle` in `html` (or a large
  # sentinel when absent), for ordering assertions.
  defp byte_index(html, needle) do
    case :binary.match(html, needle) do
      {start, _len} -> start
      :nomatch -> 1_000_000_000
    end
  end
end
