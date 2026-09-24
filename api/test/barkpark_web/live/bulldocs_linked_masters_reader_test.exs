defmodule BarkparkWeb.BulldocsLinkedMastersReaderTest do
  @moduledoc """
  The public `/papers/:slug` reader resolves LINKED master instances
  (task-59f078a2fd248698) per page load, inside the paper's own tenant and
  from PUBLISHED master rows only: a draft-only master, a foreign-tenant master
  and a missing master all read "Master unavailable". A master saved from the
  editor is published by that save (task-59be65118320fa0e item 1), and a newer
  unpublished draft of a published master never reaches the public reader.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Masters

  @dataset "production"

  defp paper!(slug, blocks, extra \\ %{}) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})
        |> Map.merge(extra)
      )

    paper
  end

  defp ref(id, master),
    do: %{"id" => id, "type" => "master-ref", "master" => master, "version" => nil}

  defp publish!(master) do
    {:ok, _} =
      Content.publish_document(Masters.master_id(master), Masters.type_name(), @dataset,
        workspace_id: master.workspace_id,
        project_id: master.project_id
      )
  end

  defp instance_paper!(slug, master_id) do
    paper!(slug, [
      %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Instance paper"},
      ref("r1", master_id)
    ])
  end

  defp source_paper!(slug, text) do
    paper!(slug, [
      %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Source"},
      %{"id" => "m", "type" => "paragraph", "text" => text}
    ])
  end

  # task-59be65118320fa0e item 1: `save_master/4` goes through
  # `Content.create_document/4`, which births every document as a DRAFT. The
  # editor's own save now publishes that draft (docs/decisions/0010 §5a), so a
  # linked instance on a published paper renders its master for the public.
  test "a master saved from the editor (draft-born) renders on the public reader",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    source_paper!("linked-reader-source-#{n}", "Shared pricing copy")

    {:ok, master} = Masters.save_master("linked-reader-source-#{n}", "m", @dataset)
    mid = Masters.master_id(master)

    # Born through the draft door, left with no draft behind: one published row.
    assert {:ok, %{doc_id: ^mid}} = Content.get_document(mid, Masters.type_name(), @dataset)

    assert {:error, :not_found} =
             Content.get_document("drafts." <> mid, Masters.type_name(), @dataset)

    instance_paper!("linked-reader-instance-#{n}", mid)

    {:ok, _view, html} = live(conn, "/papers/linked-reader-instance-#{n}")
    assert html =~ "Shared pricing copy"
    refute html =~ "Master unavailable"
  end

  test "a newer master DRAFT never reaches the public reader; the published row does",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    source_paper!("linked-reader-src2-#{n}", "Published pricing copy")
    {:ok, master} = Masters.save_master("linked-reader-src2-#{n}", "m", @dataset)
    mid = Masters.master_id(master)

    # The author edits the master and does NOT publish the edit.
    {:ok, _draft} =
      Content.upsert_document(
        Masters.type_name(),
        %{
          "doc_id" => mid,
          "title" => master.title,
          "content" => put_in(master.content, ["node", "text"], "Unpublished draft copy")
        },
        @dataset
      )

    paper = instance_paper!("linked-reader-inst2-#{n}", mid)

    {:ok, _view, html} = live(conn, "/papers/linked-reader-inst2-#{n}")
    assert html =~ "Published pricing copy"
    refute html =~ "Unpublished draft copy"

    # The authoring view (Studio) follows the draft.
    authoring = Masters.render_map(paper, paper.content["blocks"])
    assert Enum.any?(Map.values(authoring), &(&1 =~ "Unpublished draft copy"))
  end

  # task-881d4b6e857b1b65 (0010 §5b): Pin taken while the master has an
  # unpublished draft freezes the latest PUBLISHED revision, so the pinned
  # instance on a published paper renders for the public reader — before the
  # fix it froze the draft rev, which is never published, and read "Master
  # unavailable" forever.
  test "an instance pinned while the master has an unpublished draft renders publicly",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    source_paper!("linked-reader-pin-src-#{n}", "Published pinned copy")
    {:ok, master} = Masters.save_master("linked-reader-pin-src-#{n}", "m", @dataset)
    mid = Masters.master_id(master)

    {:ok, _draft} =
      Content.upsert_document(
        Masters.type_name(),
        %{
          "doc_id" => mid,
          "title" => master.title,
          "content" => put_in(master.content, ["node", "text"], "Pending draft copy")
        },
        @dataset
      )

    slug = "linked-reader-pin-#{n}"
    paper = instance_paper!(slug, mid)

    assert {:ok, pin} = Masters.pin_op(paper, "r1", true)

    assert {:ok, _receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [pin],
               @dataset,
               Ecto.UUID.generate(),
               "test:pin",
               workspace_id: paper.workspace_id,
               project_id: paper.project_id
             )

    {:ok, _view, html} = live(conn, "/papers/#{slug}")
    refute html =~ "Master unavailable"
    assert html =~ "Published pinned copy"
    refute html =~ "Pending draft copy"

    # The pin names the published row's rev (save_master returned it).
    assert [_h, %{"version" => version}] = Content.paper_blocks(slug, @dataset)
    assert version == master.rev

    # The reader really reads the PIN: once the draft is published (the latest
    # published master now says "Pending draft copy"), the pinned instance
    # still shows what it froze.
    publish!(master)

    {:ok, _view, html} = live(conn, "/papers/#{slug}")
    assert html =~ "Published pinned copy"
    refute html =~ "Pending draft copy"
    refute html =~ "Master unavailable"
  end

  test "a master that exists only as a draft (created through another door) stays unavailable",
       %{conn: conn} do
    n = System.unique_integer([:positive])

    {:ok, draft_only} =
      Content.create_document(
        Masters.type_name(),
        %{
          "title" => "Draft only",
          "content" => %{
            "tier" => "element",
            "node" => %{"id" => "m", "type" => "paragraph", "text" => "Never published copy"}
          }
        },
        @dataset
      )

    instance_paper!("linked-reader-inst3-#{n}", Masters.master_id(draft_only))

    {:ok, _view, html} = live(conn, "/papers/linked-reader-inst3-#{n}")
    assert html =~ "Master unavailable"
    refute html =~ "Never published copy"

    publish!(draft_only)

    {:ok, _view, html} = live(conn, "/papers/linked-reader-inst3-#{n}")
    assert html =~ "Never published copy"
    refute html =~ "Master unavailable"
  end

  test "a published master in another workspace reads exactly like a missing one",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    other_ws = Barkpark.TenancyFixtures.create_workspace!()
    foreign_source = "linked-reader-foreign-#{n}"

    paper!(
      foreign_source,
      [
        %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Foreign"},
        %{"id" => "m", "type" => "paragraph", "text" => "Foreign tenant copy"}
      ],
      %{"workspace_id" => other_ws.id}
    )

    {:ok, foreign} =
      Masters.save_master(foreign_source, "m", @dataset, workspace_id: other_ws.id)

    heading = %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Instance paper"}
    paper!("linked-reader-a-#{n}", [heading, ref("r1", Masters.master_id(foreign))])
    paper!("linked-reader-b-#{n}", [heading, ref("r1", "paper_master-missing-#{n}")])

    {:ok, _view, foreign_html} = live(conn, "/papers/linked-reader-a-#{n}")
    {:ok, _view, missing_html} = live(conn, "/papers/linked-reader-b-#{n}")

    assert foreign_html =~ "Master unavailable"
    refute foreign_html =~ "Foreign tenant copy"
    refute foreign_html =~ Masters.master_id(foreign)

    frame = ~r/<div class="bp-master-ref[^"]*">[^<]*<\/div>/
    assert Regex.run(frame, foreign_html) == Regex.run(frame, missing_html)
  end
end
