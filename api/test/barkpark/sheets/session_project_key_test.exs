defmodule Barkpark.Sheets.SessionProjectKeyTest do
  @moduledoc """
  Owner ruling #51, RQ7 (task-6132833921b7dc36): the Sheets session key, its
  load and its delta topics carry the project.

  Two projects in one workspace can each hold a sheet with the same slug. The
  session registry was keyed `{dataset, workspace_id, slug}` and the load read
  by workspace alone, so editors of both sheets shared one session process —
  an edit in one project could land in the other's sheet.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @ds "production"
  @slug "shared-slug-sheet"

  setup do
    ws = create_workspace!("sheet-proj-#{System.unique_integer([:positive])}")
    p1 = create_project!(ws, "sheet-one")
    p2 = create_project!(ws, "sheet-two")

    docs =
      for {p, label} <- [{p1, "one"}, {p2, "two"}], into: %{} do
        {:ok, doc} =
          create_document_in!(
            ws,
            p,
            "sheet",
            %{
              "_id" => @slug,
              "title" => "Sheet #{label}",
              "tabs" => [%{"name" => "Sheet 1", "cells" => %{"A1" => %{"v" => label}}}]
            },
            @ds
          )

        {label, doc}
      end

    on_exit(fn ->
      for doc <- Map.values(docs), do: Session.stop(@slug, @ds, doc)
    end)

    %{ws: ws, p1: p1, p2: p2, docs: docs}
  end

  defp set_a1(value), do: %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => value}

  test "same-slug sheets in two projects get two sessions, each editing its own row", ctx do
    one = ctx.docs["one"]
    two = ctx.docs["two"]
    assert one.project_id != two.project_id

    assert {:ok, %{applied: 1}} =
             Session.apply_ops(@slug, @ds, [set_a1("edited-in-one")], nil, one)

    pid_one = Session.whereis(@slug, @ds, one)
    pid_two_before = Session.whereis(@slug, @ds, two)
    assert is_pid(pid_one)
    assert pid_two_before == nil, "project two's sheet must not share project one's session"

    {:ok, peek_one} = Session.peek(@slug, @ds, one)
    assert get_in(peek_one, ["tabs", Access.at(0), "cells", "A1"]) |> inspect() =~ "edited-in-one"

    assert {:ok, %{applied: 1}} =
             Session.apply_ops(@slug, @ds, [set_a1("edited-in-two")], nil, two)

    refute Session.whereis(@slug, @ds, two) == pid_one

    {:ok, peek_two} = Session.peek(@slug, @ds, two)
    assert inspect(get_in(peek_two, ["tabs", Access.at(0), "cells", "A1"])) =~ "edited-in-two"
    {:ok, peek_one_again} = Session.peek(@slug, @ds, one)
    refute inspect(peek_one_again) =~ "edited-in-two"

    # Both persist to their own rows.
    :ok = Session.flush(@slug, @ds, one)
    :ok = Session.flush(@slug, @ds, two)

    {:ok, row_one} =
      Content.get_document("drafts." <> @slug, "sheet", @ds,
        workspace_id: ctx.ws.id,
        project_id: ctx.p1.id
      )

    refute inspect(row_one.content) =~ "edited-in-two"
  end

  test "the delta topics differ per project, and a workspace-only scope keeps the old topic",
       ctx do
    one = ctx.docs["one"]
    two = ctx.docs["two"]

    refute Session.topic(@slug, @ds, one) == Session.topic(@slug, @ds, two)
    refute Session.presence_topic(@slug, @ds, one) == Session.presence_topic(@slug, @ds, two)

    assert Session.topic(@slug, @ds, ctx.ws.id) ==
             Content.doc_topic(@slug, "sheet", ctx.ws.id, @ds) <> ":sheets:op"
  end
end
