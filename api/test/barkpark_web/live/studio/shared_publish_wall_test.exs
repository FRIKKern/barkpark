defmodule BarkparkWeb.Studio.StudioLive.SharedPublishWallTest do
  @moduledoc """
  Studio surfacing of the publish wall (authoring-excellence D14): a
  label-spine rejection must render its documentation-grade field/rule/fix
  detail in the flash — NEVER degrade to the content-free "Action failed".

  `do_action/3` is exercised directly with a minimal LiveView socket (it is
  the single seam every editor action — publish included — funnels through),
  so the assertion pins the exact flash the author reads.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared

  @details %{
    field: "tags",
    rule: "A published document requires a `tags` array.",
    fix: "Add 1–12 weighted tags: [{tag, strength, rationale}]."
  }

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        editor_doc: %{doc_id: "p1"},
        editor_type: "paper"
      }
    }
  end

  test "a label_spine rejection renders field — rule — fix, not 'Action failed'" do
    {:noreply, socket} =
      Shared.do_action(
        socket(),
        fn _doc, _type -> {:error, {:label_spine, @details}} end,
        "Published"
      )

    flash = Phoenix.Flash.get(socket.assigns.flash, :error)

    assert flash =~ "Publish blocked"
    assert flash =~ @details.field
    assert flash =~ @details.rule
    assert flash =~ @details.fix
    refute flash == "Action failed"
  end

  test "a non-wall error still falls through to the generic failure flash" do
    {:noreply, socket} =
      Shared.do_action(socket(), fn _doc, _type -> {:error, :boom} end, "Published")

    assert Phoenix.Flash.get(socket.assigns.flash, :error) == "Action failed"
  end

  # VERBATIM emitter fixture — `Barkpark.Content.TagRegistry` (tag_registry.ex:189)
  # emits exactly this shape: `%{unknown: [name], suggestions: %{name => [nearest]}}`.
  test "an unknown_tag rejection names the tag and its suggestion, not 'Action failed'" do
    {:noreply, socket} =
      Shared.do_action(
        socket(),
        fn _doc, _type ->
          {:error, {:unknown_tag, %{unknown: ["serach"], suggestions: %{"serach" => ["search"]}}}}
        end,
        "Published"
      )

    flash = Phoenix.Flash.get(socket.assigns.flash, :error)

    assert flash =~ "Publish blocked"
    assert flash =~ "unknown tag 'serach'"
    assert flash =~ "did you mean 'search'?"
    refute flash == "Action failed"
  end

  # VERBATIM emitter fixture — `Barkpark.Content.DedupWall` (dedup_wall.ex:138-140)
  # emits the FIXED generic `:message` prose (which lacks the id) plus the incumbent
  # id in `:duplicate_of`, the full `:similar` list, and `:advise`.
  test "a duplicate_of rejection surfaces the incumbent id and the fix, not 'Action failed'" do
    {:noreply, socket} =
      Shared.do_action(
        socket(),
        fn _doc, _type ->
          {:error,
           {:duplicate_of,
            %{
              message:
                "this document near-duplicates the already-published paper-live — " <>
                  "extend that document instead, or, if this one REPLACES it, declare " <>
                  "content.supersedes: \"paper-live\" and republish (the wall exempts " <>
                  "exactly the declared pair; any other near-duplicate still refuses)",
              duplicate_of: "paper-live",
              similar: [%{id: "paper-live", similarity: 0.92, shared_tokens: 5}],
              advise: []
            }}}
        end,
        "Published"
      )

    flash = Phoenix.Flash.get(socket.assigns.flash, :error)

    assert flash =~ "Publish blocked"
    assert flash =~ "duplicate of paper-live"
    assert flash =~ "content.supersedes"
    refute flash =~ "differentiate this one's title/tags"
    refute flash == "Action failed"
  end

  describe "format_wall_details/1" do
    test "renders a single field/rule/fix map as one documentation line" do
      assert Shared.format_wall_details(@details) ==
               Enum.join([@details.field, @details.rule, @details.fix], " — ")
    end

    test "renders a LIST of violations joined for the flash" do
      line = Shared.format_wall_details([@details, %{field: "description", rule: "r", fix: "f"}])
      assert line =~ @details.rule
      assert line =~ " · "
      assert line =~ "description — r — f"
    end

    test "an unknown detail shape degrades LOUDLY (inspected), never silently" do
      assert Shared.format_wall_details(:weird) == inspect(:weird)
      assert Shared.format_wall_details(%{other: "shape"}) == inspect(%{other: "shape"})
    end

    test "renders an unknown_tag payload as per-name prose with best-first suggestions" do
      line =
        Shared.format_wall_details(%{
          unknown: ["serach", "medai"],
          suggestions: %{"serach" => ["search"], "medai" => ["media", "meta"]}
        })

      assert line =~ "unknown tag 'serach' — did you mean 'search'?"
      assert line =~ "unknown tag 'medai' — did you mean 'media', 'meta'?"
      assert line =~ " · "
    end

    test "an unknown_tag name with no suggestion renders bare, never crashes" do
      assert Shared.format_wall_details(%{unknown: ["zzz"], suggestions: %{}}) ==
               "unknown tag 'zzz'"
    end

    test "renders a duplicate_of payload from the incumbent id, never :message alone" do
      line =
        Shared.format_wall_details(%{
          message:
            "this document near-duplicates the already-published paper-live — " <>
              "extend that document instead, or, if this one REPLACES it, declare " <>
              "content.supersedes: \"paper-live\" and republish (the wall exempts " <>
              "exactly the declared pair; any other near-duplicate still refuses)",
          duplicate_of: "paper-live",
          similar: [%{id: "paper-live", similarity: 0.92, shared_tokens: 5}],
          advise: []
        })

      assert line ==
               "duplicate of paper-live — extend that document, or declare " <>
                 "content.supersedes: \"paper-live\" if this one replaces it"
    end
  end
end

defmodule BarkparkWeb.Studio.StudioLive.SharedPublishWallBulkTest do
  @moduledoc """
  Bulk-publish surfacing of the publish wall (authoring-excellence D80/D82):
  `bulk_action`'s flash was UNPINNED until this wave — a wall rejection in a
  batch must count as WALLED (a fix-carrying block), never fold into the generic
  "N failed" tally. Proven end-to-end through a real Studio mount: two draft
  tasks whose tags are deliberately UNREGISTERED trip the E3 tag-registry wall,
  so a bulk publish reports them as "blocked by the publish wall" — the
  first-ever bulk wall-count coverage.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tasks}
  alias Barkpark.Content.DraftId

  @dataset "production"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    # Two wall-COMPLIANT drafts (valid description + 1–12 distinct-strength
    # weighted tags with rationales) whose tag NAMES are deliberately never
    # registered — so each clears the label-spine (E1/E2) and is rejected at the
    # E3 tag registry with `{:error, {:unknown_tag, _}}`. Distinct titles +
    # per-doc unique description tokens keep task create-dedup out of the way.
    for n <- ["a", "b"] do
      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => "wall-bulk-#{n}",
            "title" => "Wall bulk fixture #{n}",
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "description" => "Bulk wall fixture #{n}: zzq#{n}1 zzq#{n}2 zzq#{n}3 zzq#{n}4.",
              "tags" => [
                %{
                  "tag" => "unreg-#{n}-alpha",
                  "strength" => 90,
                  "rationale" => "Deliberately unregistered tag ##{n}a for the bulk wall test."
                },
                %{
                  "tag" => "unreg-#{n}-beta",
                  "strength" => 40,
                  "rationale" => "Deliberately unregistered tag ##{n}b for the bulk wall test."
                }
              ]
            }
          },
          @dataset,
          scope
        )
    end

    :ok
  end

  test "a bulk publish counts wall rejections as WALLED, never 'N failed'", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task"))

    _ = render_click(view, "toggle-doc-checkbox", %{"id" => "wall-bulk-a"})
    _ = render_click(view, "toggle-doc-checkbox", %{"id" => "wall-bulk-b"})
    html = render_click(view, "bulk-publish", %{})

    # Both were routed to the WALL accumulator with a concrete fix line — not the
    # content-free failure tally.
    assert html =~ "Published 0 of 2"
    assert html =~ "blocked by the publish wall"
    assert html =~ "unknown tag"
    refute html =~ "failed"

    # …and neither doc published (the wall is fail-closed) — no published row
    # exists for either id, while the drafts survive for the author to fix.
    assert {:error, :not_found} = Content.get_document("wall-bulk-a", "task", @dataset)
    assert {:error, :not_found} = Content.get_document("wall-bulk-b", "task", @dataset)

    assert {:ok, %{status: "draft"}} =
             Content.get_document(DraftId.draft_id("wall-bulk-a"), "task", @dataset)
  end
end
