defmodule BarkparkWeb.Studio.TreeCodelistRemoveRaceTest do
  @moduledoc """
  task-39426106a2913be5 (review of #27740): editor A presses Remove on a
  tree codelist while editor B's pick of a new code is on its way. A's
  Remove was handled from A's stale copy and unset the field, so B's new
  code was lost and no one was told. That held in the desk and in the old
  Studio, for a code and for a stored value that is no code.

  A Remove now reads the field from the store first. When the value at its
  path is no longer the one A's editor holds, nothing is written: B's code
  stays, and A's page draws it when B's save reaches it, as the TanStack
  Studio keeps another editor's newer value. A change elsewhere in the
  same object (a sibling key) does not stop the Remove.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:tree-race-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Tree race",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children:
              for(
                i <- 1..101,
                do: %{code: "FB#{i}", translations: [%{language: "eng", label: "F#{i}"}]}
              )
          }
        ]
      })

    type = "tr_book_#{n}"
    tree = %{"type" => "codelist", "codelistId" => list_id}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Tree race",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            Map.merge(tree, %{"name" => "subject", "title" => "Subject"}),
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                Map.merge(tree, %{"name" => "code", "title" => "Code"}),
                %{"name" => "label", "title" => "Label", "type" => "string"}
              ]
            }
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    ws_id = Tenancy.get_default_workspace().id

    conns =
      for who <- ["a", "b"] do
        raw = "tree-race-#{who}-" <> Ecto.UUID.generate()

        {:ok, _} =
          Auth.create_token(raw, "tree-race-#{who}", @dataset, ~w(read write admin), ws_id)

        Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{"api_token" => raw})
      end

    _ = conn

    {:ok, conns: conns, root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio", type: type}
  end

  defp doc!(c, content) do
    id = "tr-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => content},
        @dataset
      )

    id
  end

  defp open(conn, c, :desk, id) do
    {:ok, view, _} = live(conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  defp open(conn, c, :studio, id) do
    {:ok, view, _} = live(conn, "#{c.root}/#{c.type}/#{id}")
    assert has_element?(view, "#editor-form")
    view
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp mark(c, id), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, id)}

  # The tree's pick (and its Remove, "") reaches the page as this message.
  defp pick_msg(c, id, name, code),
    do: {:tree_codelist_pick, %{name: name, value: code, press: mark(c, id)}}

  # A's Remove is queued in A's process before B's pick lands; A handles it
  # after, from a copy that has not seen B's code.
  defp race(c, id, surface, name, b_write) do
    [ca, cb] = c.conns
    a = open(ca, c, surface, id)
    b = open(cb, c, surface, id)

    :sys.suspend(a.pid)
    send(a.pid, pick_msg(c, id, name, ""))
    b_write.(b)
    render(b)
    :sys.resume(a.pid)
    render(a)
    a
  end

  defp b_pick(c, id, name, code), do: fn b -> send(b.pid, pick_msg(c, id, name, code)) end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: A's Remove that has not seen B's new code leaves B's code", c do
      id = doc!(c, %{"subject" => "FB2"})
      race(c, id, @surface, "doc[subject]", b_pick(c, id, "doc[subject]", "FB1"))
      assert stored(c, id)["subject"] == "FB1"
    end

    test "#{surface}: the same over a stored value that is no code", c do
      id = doc!(c, %{"subject" => 7})
      race(c, id, @surface, "doc[subject]", b_pick(c, id, "doc[subject]", "FB1"))
      assert stored(c, id)["subject"] == "FB1"
    end

    test "#{surface}: nested, A's Remove of meta.code leaves B's new code", c do
      id = doc!(c, %{"meta" => %{"code" => "FB2", "label" => "x"}})
      race(c, id, @surface, "doc[meta].code", b_pick(c, id, "doc[meta].code", "FB3"))
      assert stored(c, id)["meta"] == %{"code" => "FB3", "label" => "x"}
    end
  end

  for {surface, form, left} <- [
        {:desk, "[data-pane-editing] #editor-form", %{"label" => "fromB"}},
        # The old Studio stores "" at a nested path, as it did.
        {:studio, "#editor-form", %{"code" => "", "label" => "fromB"}}
      ] do
    @surface surface
    @form_sel form
    @left left

    test "#{surface}: B's edit of a sibling key does not stop A's Remove, and stays", c do
      id = doc!(c, %{"meta" => %{"code" => "FB2", "label" => "x"}})

      # A nested input's name is dotted and arrives whole.
      race(c, id, @surface, "doc[meta].code", fn b ->
        b
        |> element(@form_sel)
        |> render_change(%{"doc[meta].label" => "fromB", "_target" => ["doc[meta].label"]})

        assert stored(c, id)["meta"] == %{"code" => "FB2", "label" => "fromB"}
      end)

      assert stored(c, id)["meta"] == @left
    end
  end

  test "desk: A has seen B's pick, then Removes it: it goes", c do
    id = doc!(c, %{"subject" => "FB2"})
    [ca, cb] = c.conns
    a = open(ca, c, :desk, id)
    b = open(cb, c, :desk, id)

    send(b.pid, pick_msg(c, id, "doc[subject]", "FB1"))
    render(b)
    render(a)
    assert stored(c, id)["subject"] == "FB1"

    send(a.pid, pick_msg(c, id, "doc[subject]", ""))
    render(a)
    refute Map.has_key?(stored(c, id), "subject")
  end

  test "desk: with no race, Remove still clears the code", c do
    id = doc!(c, %{"subject" => "FB2"})
    [ca, _] = c.conns
    a = open(ca, c, :desk, id)
    send(a.pid, pick_msg(c, id, "doc[subject]", ""))
    render(a)
    refute Map.has_key?(stored(c, id), "subject")
  end
end
