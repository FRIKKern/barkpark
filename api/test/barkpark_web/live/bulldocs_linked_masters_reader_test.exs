defmodule BarkparkWeb.BulldocsLinkedMastersReaderTest do
  @moduledoc """
  The public `/papers/:slug` reader resolves LINKED master instances
  (task-59f078a2fd248698) per page load, inside the paper's own tenant and
  from PUBLISHED master rows only: a draft-only master, a foreign-tenant master
  and a missing master all read "Master unavailable".
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

  test "an instance renders its published master; a draft-only master is unavailable",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    source = "linked-reader-source-#{n}"
    instance = "linked-reader-instance-#{n}"

    paper!(source, [
      %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Source"},
      %{"id" => "m", "type" => "paragraph", "text" => "Shared pricing copy"}
    ])

    {:ok, master} = Masters.save_master(source, "m", @dataset)

    paper!(instance, [
      %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Instance paper"},
      ref("r1", Masters.master_id(master))
    ])

    {:ok, _view, html} = live(conn, "/papers/#{instance}")
    assert html =~ "Master unavailable"
    refute html =~ "Shared pricing copy"

    publish!(master)

    {:ok, _view, html} = live(conn, "/papers/#{instance}")
    assert html =~ "Shared pricing copy"
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

    publish!(foreign)

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
