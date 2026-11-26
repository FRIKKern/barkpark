defmodule BarkparkWeb.Studio.HeldWholeFormWriteTest do
  @moduledoc """
  task-881a41cd3227e73c: while a text field is held (B's save is stored, A's
  words wait in the form under the banner, and autosave of that field is
  paused), a write that saves the whole editor form wrote A's held words over
  B's save and cleared the banner. The writes: an array op, a tag press, a
  tree codelist pick and a slug Generate, each on another field
  (`BarkparkWeb.HeldWrites`). Each now writes its own field, keeps B's value
  in the store, and leaves A's words, the banner and the paused line as they
  were.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.HeldWrites
  alias BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @label "doc[meta].label"
  @t0 "one two three"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "held_write_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Held writes",
          "visibility" => "public",
          "fields" =>
            [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "meta",
                "title" => "Meta",
                "type" => "composite",
                "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
              },
              %{"name" => "notes", "title" => "Notes", "type" => "string"}
            ] ++ HeldWrites.fields()
        },
        @dataset
      )

    id = "held-write-#{n}"
    content = Map.merge(%{"meta" => %{"label" => @t0}, "notes" => @t0}, HeldWrites.content())

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "T0", "content" => content},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "held-write-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "held-write",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

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
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp label(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    get_in(doc.content, ["meta", "label"])
  end

  defp form_label(view),
    do: get_in(:sys.get_state(view.pid).socket.assigns[:editor_form], ["meta", "label"])

  # The page's `_bp_seen` as bp-array-focus.js keeps it.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    seen = value |> String.replace("&quot;", ~s(")) |> Jason.decode!()
    assert_push_event(view, "bp:form-born", %{seqs: seqs, oks: oks}, 2_000)
    seen |> Map.merge(seqs) |> Map.put("v", 2) |> Map.put("ok", Map.merge(seen["ok"] || %{}, oks))
  end

  defp confirmed(view, seen) do
    assert_push_event(view, "bp:form-confirmed", %{oks: oks}, 2_000)
    Map.update!(seen, "ok", &Map.merge(&1, oks))
  end

  defp changes(view, label, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "doc" => %{"title" => "T0", "notes" => @t0},
      @label => label,
      "_bp_seen" => Jason.encode!(seen),
      "_target" => [@label]
    })
  end

  # A's label is held: A typed " A1" and it landed, the socket dropped, B
  # saved "B5 …", and A's rejoined page typed " A7" on the old value.
  defp held(c, surface) do
    a = open(c, surface)
    seen = page(a)
    changes(a, @t0 <> " A1", seen)
    seen = confirmed(a, seen)
    GenServer.stop(a.pid, :normal)

    b = open(c, surface)
    changes(b, "B5 " <> @t0 <> " A1", page(b))
    GenServer.stop(b.pid, :normal)

    a2 = open(c, surface)
    _ = page(a2)
    changes(a2, @t0 <> " A1 A7", seen)
    assert label(c) == "B5 " <> @t0 <> " A1"
    assert has_element?(a2, @paused)
    a2
  end

  for surface <- [:desk, :studio], path <- HeldWrites.paths() do
    test "#{surface} #{path} on another field while the label is held: B's label stays, A's words and the banner too",
         c do
      a = held(c, unquote(surface))

      HeldWrites.run(a, c, unquote(path))

      HeldWrites.landed(c, unquote(path))
      # On main: the label was written as A's "… A1 A7", the banner gone.
      assert label(c) == "B5 " <> @t0 <> " A1"
      assert form_label(a) == @t0 <> " A1 A7"
      assert has_element?(a, @banner)
      assert has_element?(a, @paused, "Autosave is paused for Meta until you Save or Reload.")
    end
  end
end
