defmodule BarkparkWeb.Studio.StudioPaperPublishAffordanceTest do
  @moduledoc """
  spd-bl-publish-affordance-triple — the hand path can now SATISFY the
  publish wall.

  Three measured absences (each a DOM binary before the fix): no Publish
  control on the paper pane, no description input anywhere in the Studio, no
  tag-add affordance in the Labels section. The publish wall itself is
  UNCHANGED (charter D229/D230) — these tests drive a hand-created
  `drafts.<slug>` paper through the wall's own refusals, in the wall's own
  order, entirely through LiveView events, and read every persisted claim back
  FROM THE STORE (`Content.get_document/3`), never from the DOM.

  The refusal order is the wall's, re-derived from the code and pinned here:
  `Lifecycle.publish_after_gate` runs `AuthoringWall.enforce` (description
  first and always) BEFORE the Bulldocs `before_publish` hook (the hollow-body
  halt), so a skeleton draft with no description is told about the description
  first, and the block-0-heading skeleton trap ("title + one heading is still
  no content") surfaces once the metadata is satisfied.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @tag_name "affordance-walk-tag"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  # A registered tag = a PUBLISHED `type:tag` doc whose doc_id IS the tag name
  # (TagRegistry.registered_subset matches on doc_id). Born a draft (writer
  # coerces), then published — the tag type is not walled, so this is clean.
  defp register_tag!(name) do
    {:ok, draft} =
      Content.create_document("tag", %{"doc_id" => name, "title" => name}, @dataset)

    assert draft.doc_id == "drafts.#{name}"
    {:ok, _pub} = Content.publish_document(name, "tag", @dataset)
    :ok
  end

  defp create_draft_paper!(slug, blocks) do
    {:ok, doc} =
      Content.create_document(
        "paper",
        %{"doc_id" => slug, "title" => "Untitled", "content" => %{"blocks" => blocks}},
        @dataset
      )

    assert doc.doc_id == "drafts.#{slug}"
    doc
  end

  # The de-facto-title shape of the skeleton trap: block 0 is a heading (the
  # un-migrated corpus's title), and nothing else carries authored text.
  defp skeleton_blocks do
    [
      %{
        "id" => "b0",
        "type" => "heading",
        "level" => 1,
        "content" => [%{"type" => "text", "value" => "A Fine Title"}]
      }
    ]
  end

  defp content_paragraph do
    %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Real authored prose lives here."}]
    }
  end

  defp open_paper(conn, slug) do
    live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
  end

  defp flash(view, kind) do
    :sys.get_state(view.pid).socket.assigns.flash[kind]
  end

  defp draft_content!(slug) do
    {:ok, doc} = Content.get_document("drafts.#{slug}", "paper", @dataset)
    doc.content
  end

  setup do
    # Pin the canvas default ON (mirrors studio_live_new_paper_journey_test —
    # sibling suites set "0" process-globally; async: false makes this safe).
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    seed_paper_schema!()
    :ok
  end

  describe "the Publish control" do
    test "is present with accessible name Publish on a draft, absent on a published paper",
         %{conn: conn} do
      create_draft_paper!("affordance-pub-presence", skeleton_blocks())
      {:ok, _view, html} = open_paper(conn, "affordance-pub-presence")

      [button] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s(button[data-test-id="paper-publish"]))
        |> Enum.to_list()

      name =
        case LazyHTML.attribute(button, "aria-label") do
          [label | _] -> String.trim(label)
          [] -> button |> LazyHTML.text() |> String.trim()
        end

      assert name == "Publish"

      # The contrast arm: an in-place-published paper (upsert_paper writes the
      # published row directly, no drafts twin) must NOT offer a control whose
      # action could never succeed. upsert_paper mounts the SAME wall, so the
      # fixture must satisfy it: description + one registered weighted tag.
      register_tag!(@tag_name)

      {:ok, _} =
        Content.upsert_paper(%{
          "slug" => "affordance-already-published",
          "type" => "paper",
          "title" => "Already Published",
          "dataset" => @dataset,
          "blocks" => [skeleton_blocks() |> hd(), content_paragraph()],
          "description" => "An in-place-published contrast fixture for the control.",
          "tags" => [
            %{
              "tag" => @tag_name,
              "strength" => 70,
              "rationale" => "Names the contrast fixture's subject precisely."
            }
          ]
        })

      {:ok, _view2, html2} = open_paper(conn, "affordance-already-published")
      refute html2 =~ ~s(data-test-id="paper-publish")
    end
  end

  describe "the sidebar metadata affordances" do
    test "the description input round-trips to content[description] in the store",
         %{conn: conn} do
      create_draft_paper!("affordance-desc", skeleton_blocks())
      {:ok, view, html} = open_paper(conn, "affordance-desc")

      assert html =~ ~s(data-test-id="sidebar-description-input")

      value = "A description long enough to satisfy the twenty-character floor."

      view
      |> element(~s(form[phx-change="sidebar-description-change"]))
      |> render_change(%{"value" => value})

      assert draft_content!("affordance-desc")["description"] == value,
             "the sidebar description edit must persist to the STORED document"
    end

    test "the label add affordance writes one complete weighted-tag entry", %{conn: conn} do
      create_draft_paper!("affordance-label", skeleton_blocks())
      {:ok, view, html} = open_paper(conn, "affordance-label")

      assert html =~ ~s(data-test-id="sidebar-label-add")

      view
      |> element(~s(form[data-test-id="sidebar-label-add"]))
      |> render_submit(%{
        "tag" => @tag_name,
        "strength" => "80",
        "rationale" => "This tag names the walk's subject precisely."
      })

      assert [entry] = draft_content!("affordance-label")["tags"]
      assert entry["tag"] == @tag_name
      assert entry["strength"] == 80
      assert entry["rationale"] == "This tag names the walk's subject precisely."

      # …and the persisted chip renders back into the Labels section.
      assert render(view) =~ @tag_name
    end

    test "an incomplete label entry is refused in plain words, and nothing persists",
         %{conn: conn} do
      create_draft_paper!("affordance-label-short", skeleton_blocks())
      {:ok, view, _html} = open_paper(conn, "affordance-label-short")

      view
      |> element(~s(form[data-test-id="sidebar-label-add"]))
      |> render_submit(%{"tag" => @tag_name, "strength" => "80", "rationale" => "too short"})

      assert flash(view, "error") =~ "rationale of at least 20 characters"
      refute is_list(draft_content!("affordance-label-short")["tags"])
    end
  end

  describe "the walk — draft to published, entirely through the UI" do
    test "each wall refusal surfaces in plain language, then the publish lands",
         %{conn: conn} do
      register_tag!(@tag_name)
      create_draft_paper!("affordance-walk", skeleton_blocks())
      {:ok, view, _html} = open_paper(conn, "affordance-walk")

      # STEP 1 — publish a bare skeleton: the wall's FIRST refusal is the
      # description (metadata, not content), in the validator's own
      # documentation-grade wording — never a raw error atom.
      view |> element(~s(button[data-test-id="paper-publish"])) |> render_click()
      step1 = flash(view, "error")
      assert step1 =~ "Publish blocked:"
      assert step1 =~ "description"
      refute step1 =~ "label_spine", "the raw error atom must never reach the human"

      # STEP 2 — satisfy the metadata through the sidebar (description + one
      # registered weighted tag), then publish again: the block-0-heading
      # skeleton trap fires, in words a human can act on. A paper with a title
      # and one heading is told it still needs content.
      view
      |> element(~s(form[phx-change="sidebar-description-change"]))
      |> render_change(%{"value" => "A walkable paper proving the hand path end to end."})

      view
      |> element(~s(form[data-test-id="sidebar-label-add"]))
      |> render_submit(%{
        "tag" => @tag_name,
        "strength" => "80",
        "rationale" => "This tag names the walk's subject precisely."
      })

      view |> element(~s(button[data-test-id="paper-publish"])) |> render_click()
      step2 = flash(view, "error")

      assert step2 =~ "no content yet",
             "expected the hollow-body copy (the block-0-heading skeleton trap " <>
               "surfaced honestly), got: #{inspect(step2)}"

      assert step2 =~ "add at least one body block",
             "the refusal must say what to DO, not only what is wrong"

      # STEP 3 — add one real paragraph through the canvas op path, publish,
      # and verify against the STORE: published row exists, draft is gone.
      view
      |> render_hook("paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "ops" => [%{"op" => "insert-after", "afterId" => "b0", "block" => content_paragraph()}]
      })

      view |> element(~s(button[data-test-id="paper-publish"])) |> render_click()

      info = flash(view, "info")

      assert info && info =~ "Published",
             "expected the publish to land; error flash: #{inspect(flash(view, "error"))}"

      assert {:ok, published} = Content.get_document("affordance-walk", "paper", @dataset)
      assert published.status == "published"
      assert published.content["description"] =~ "walkable paper"
      assert [%{"tag" => @tag_name}] = published.content["tags"]

      assert {:error, :not_found} =
               Content.get_document("drafts.affordance-walk", "paper", @dataset)
    end
  end
end
