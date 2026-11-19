defmodule BarkparkWeb.Studio.DeskRemoteSaveTest do
  @moduledoc """
  task-6b336810643b1a70 (review of #27622): another editor's save on the
  desk footer (`Desk.RemoteSave`).

  - A save that replaced or dropped a value this tab saved keeps "Updated
    by another user": overlapping splices, a post with no base text, a date
    both picked. One that kept every value (another field, J06's two ends
    of one title) does not.
  - A remote save of the draft is the draft's state in a tab that never
    typed: "Edited just now", Publish offered. A Publish elsewhere closes
    it: "Last published just now", Publish greyed out.

  The posts are the page's, as in `two_editors_in_flight_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @status ~s([data-pane-editing] .dk-edit-footer [data-desk-footer-status] .save-state-text)
  @publish ~s([data-pane-editing] [data-desk-publish])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rs_#{n}"
    doc_id = "rs-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Remote saves #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "day", "title" => "Day", "type" => "date"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Hello world",
          "content" => %{"excerpt" => "First", "day" => "2026-01-01"}
        },
        @dataset
      )

    # The "Saved" window, short: the footer's words after it are the ones read here.
    Application.put_env(:barkpark, :desk_saved_ms, 100)
    on_exit(fn -> Application.delete_env(:barkpark, :desk_saved_ms) end)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-remote-save-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-remote-save", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, desk: "#{base}/_desk/#{type};#{doc_id}", type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp status(view), do: view |> element(@status) |> render() |> strip()
  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  # The footer's words once this tab's "Saved" is over and the frames are in.
  defp settled(view) do
    Process.sleep(200)
    render(view)
    status(view)
  end

  defp form_of(view) do
    :sys.get_state(view.pid).socket.assigns.editor_form
    |> Map.take(["title", "excerpt", "day"])
  end

  defp send_post(view, target, changes, seen \\ %{}) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form_of(view), changes),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: values} = payload, 2_000)
    {values, Map.get(payload, :seqs, %{})}
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(Map.take(doc.content || %{}, ["excerpt", "day"]), "title", doc.title)
  end

  describe "another editor's save that replaced a value this tab saved is named" do
    test "overlapping splices in one text: A's word is gone, A is told", c do
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Hello there"})

      # B typed from "Hello world": its page reports the old value's number.
      {_values, seqs} = told(b)
      [was, _new] = seqs["doc[title]"]
      send_post(b, "title", %{"title" => "Hello everyone"}, %{"doc[title]" => was, "v" => 2})
      assert stored(c)["title"] == "Hello everyone"

      assert settled(a) == "Updated by another user"
    end

    test "a post with no base text: A's words are gone, A is told", c do
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Hello world A7"})
      told(b)
      send_post(b, "title", %{"title" => "Hello world B3"})
      assert stored(c)["title"] == "Hello world B3"

      assert settled(a) == "Updated by another user"
    end

    test "a date both picked: A's is replaced, A is told; A's next save ends it", c do
      a = open(c)
      b = open(c)
      send_post(a, "day", %{"day" => "2026-02-15"})
      send_post(b, "day", %{"day" => "2026-03-03"})
      assert stored(c)["day"] == "2026-03-03"

      assert settled(a) == "Updated by another user"

      send_post(a, "excerpt", %{"excerpt" => "Again"})
      assert settled(a) == "Edited just now"
    end
  end

  describe "another editor's save that kept every value this tab saved is not named" do
    test "another field", c do
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Hello there"})
      told(b)
      send_post(b, "excerpt", %{"excerpt" => "Second"})

      assert stored(c) |> Map.take(["title", "excerpt"]) == %{
               "title" => "Hello there",
               "excerpt" => "Second"
             }

      assert settled(a) == "Edited just now"
    end

    test "J06: the two ends of one title, both kept", c do
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Hello world A"})

      {_values, seqs} = told(b)
      [was, _new] = seqs["doc[title]"]
      send_post(b, "title", %{"title" => "B Hello world"}, %{"doc[title]" => was, "v" => 2})
      assert stored(c)["title"] == "B Hello world A"

      assert settled(a) == "Edited just now"

      # The kept change follows the text: a later save of another field stays quiet.
      send_post(b, "excerpt", %{"excerpt" => "Second"})
      assert settled(a) == "Edited just now"
    end
  end

  describe "the draft's state follows another editor's saves" do
    test "a tab that never typed: another editor's draft is Edited, with Publish offered", c do
      {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)
      a = open(c)
      b = open(c)
      assert status(b) == "Last published just now"
      assert has_element?(b, @publish <> "[disabled]")

      send_post(a, "title", %{"title" => "Hello from A"})
      told(b)

      assert settled(b) == "Edited just now"
      refute has_element?(b, @publish <> "[disabled]")
    end

    test "a draft published elsewhere: Last published, with Publish greyed out", c do
      b = open(c)
      send_post(b, "title", %{"title" => "Hello B"})
      assert settled(b) == "Edited just now"
      refute has_element?(b, @publish <> "[disabled]")

      {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)

      assert settled(b) == "Last published just now"
      assert has_element?(b, @publish <> "[disabled]")
    end
  end
end
