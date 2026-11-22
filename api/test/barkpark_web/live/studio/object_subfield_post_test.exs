defmodule BarkparkWeb.Studio.ObjectSubfieldPostTest do
  @moduledoc """
  task-04e50efa8405b956: B saves `meta.label`, then a post from A that
  changes `meta.code` arrives, carrying the label A's page showed before
  B's save. The object was written whole, so A's old label went over B's.
  A's post writes only the subfields A changed, as TanStack writes one path
  per change: the store keeps B's label and takes A's code. The form buffer
  takes the same subfields, so A's next post does not send A's old label
  back as an edit.

  The three stale-post tests run in the desk only. In the old Studio the
  list topic's frame reloads `editor_doc` to B's row before the stale post
  arrives, so the post is read as an edit of every value it carries, at the
  top level as inside an object: another cause, task-9db9c20cd53351ab (as in
  `StalePostKeepsRemoteTest`). The set-back test runs in both.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "subfield_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Subfield posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "code", "title" => "Code", "type" => "string"},
                %{"name" => "label", "title" => "Label", "type" => "string"}
              ]
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "subfield-post-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"code" => "c0", "label" => "l0"}, "notes" => "n0"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "subfield-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "subfield", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A post as the page sends it: every input, the object's subfields under
  # their dotted names, `target` the input that changed.
  defp posts(view, target, flat, meta) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => flat,
      "doc[meta].code" => meta["code"],
      "doc[meta].label" => meta["label"]
    })
  end

  # A post built from what A's form buffer draws now, `key` changed.
  defp from_buffer(view, target, changes) do
    form = assigns(view).editor_form
    flat = form |> Map.take(~w(title notes)) |> Map.merge(Map.drop(changes, ["meta"]))
    meta = Map.merge(form["meta"] || %{}, changes["meta"] || %{})
    posts(view, target, flat, meta)
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  @flat %{"title" => "T0", "notes" => "n0"}

  # B saved `meta.label` "lB", and A's page has taken B's save in.
  defp b_saved_label(c, surface) do
    a = open(c, surface)
    b = open(c, surface)
    posts(b, "doc[meta].label", @flat, %{"code" => "c0", "label" => "lB"})
    assert eventually(fn -> stored(c)["meta"] == %{"code" => "c0", "label" => "lB"} end)
    assert eventually(fn -> assigns(a).editor_form["meta"]["label"] == "lB" end)
    a
  end

  test "desk: A's code change keeps B's newer label", c do
    a = b_saved_label(c, :desk)

    # The post left A's page before B's save reached it.
    posts(a, "doc[meta].code", @flat, %{"code" => "cA", "label" => "l0"})

    assert eventually(fn -> stored(c)["meta"]["code"] == "cA" end)
    assert stored(c)["meta"] == %{"code" => "cA", "label" => "lB"}
  end

  test "desk: A's next post after the code change keeps B's label", c do
    a = b_saved_label(c, :desk)
    posts(a, "doc[meta].code", @flat, %{"code" => "cA", "label" => "l0"})
    assert eventually(fn -> stored(c)["meta"]["code"] == "cA" end)
    assert assigns(a).editor_form["meta"] == %{"code" => "cA", "label" => "lB"}

    from_buffer(a, "doc[notes]", %{"notes" => "nA"})

    assert eventually(fn -> stored(c)["notes"] == "nA" end)
    assert stored(c)["meta"] == %{"code" => "cA", "label" => "lB"}
  end

  test "desk: a post equal to A's own object writes nothing over B's label", c do
    a = b_saved_label(c, :desk)

    # A typed a letter in the code and took it back inside one post.
    posts(a, "doc[meta].code", @flat, %{"code" => "c0", "label" => "l0"})
    from_buffer(a, "doc[notes]", %{"notes" => "nA"})

    assert eventually(fn -> stored(c)["notes"] == "nA" end)
    assert stored(c)["meta"] == %{"code" => "c0", "label" => "lB"}
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a code set back to A's own after B's is saved", c do
      a = open(c, @surface)
      b = open(c, @surface)
      posts(a, "doc[meta].code", @flat, %{"code" => "cA", "label" => "l0"})
      assert eventually(fn -> stored(c)["meta"]["code"] == "cA" end)
      posts(b, "doc[meta].code", @flat, %{"code" => "cB", "label" => "l0"})
      assert eventually(fn -> assigns(a).editor_form["meta"]["code"] == "cB" end)

      from_buffer(a, "doc[meta].code", %{"meta" => %{"code" => "cA"}})

      assert eventually(fn -> stored(c)["meta"]["code"] == "cA" end)
      assert stored(c)["meta"] == %{"code" => "cA", "label" => "l0"}
    end
  end
end
