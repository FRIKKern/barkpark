defmodule BarkparkWeb.Studio.StaleDocFrameTest do
  @moduledoc """
  task-e7088bb3b4139db7: two people type in one field at the same moment.

  B's save lands, then A's save is written over it, and only then does B's
  `{:doc_updated, …}` frame reach A's process (it was busy saving). The frame
  still carries B's text alone. A's form took it and told the page, so A's
  input showed B's post, not what the store held, until the next change.

  The tests hold B's frames back from A (A leaves the doc topics; the test
  joins them and keeps what B's save sends), let A save, then hand A the
  frames in the order PubSub sends them.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "sdf_post_#{n}"
    doc_id = "sdf-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "SDF posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "day", "title" => "Day", "type" => "date"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Fixture post", "content" => %{"day" => "2026-01-01"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "stale-frame-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "stale-frame", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     url: "#{base}/#{type}/#{doc_id}",
     desk: "#{base}/_desk/#{type};#{doc_id}",
     type: type,
     doc_id: doc_id}
  end

  defp open(c, url) do
    {:ok, view, _html} = live(c.conn, url)
    view
  end

  defp form_of(view) do
    :sys.get_state(view.pid).socket.assigns.editor_form |> Map.take(["title", "day"])
  end

  # `seen` is `_bp_seen` as bp-array-focus.js keeps it (`RemoteValues`).
  defp send_post(view, target, changes, seen \\ %{}) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form_of(view), changes),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # The number of the value a push told the page, for `_bp_seen`.
  defp told_seq(view, name) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{seqs: %{^name => [_was, new]}})
    new
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    %{"title" => doc.title, "day" => (doc.content || %{})["day"]}
  end

  # A leaves every document topic it joined; the test joins them instead, so
  # it gets the frames a save sends and A does not. The desk opens its editor
  # after mount, so A can join the doc topic a moment after the list topic.
  defp hold_frames_from(view, tries \\ 50) do
    render(view)

    topics =
      Barkpark.PubSub
      |> Registry.keys(view.pid)
      |> Enum.filter(&String.starts_with?(&1, "doc"))

    if Enum.any?(topics, &String.starts_with?(&1, "doc:")) or tries == 0 do
      hold(view, topics)
    else
      Process.sleep(20)
      hold_frames_from(view, tries - 1)
    end
  end

  defp hold(view, topics) do
    assert Enum.any?(topics, &String.starts_with?(&1, "doc:"))

    :sys.replace_state(view.pid, fn state ->
      Enum.each(topics, &Phoenix.PubSub.unsubscribe(Barkpark.PubSub, &1))
      state
    end)

    Enum.each(topics, &Phoenix.PubSub.subscribe(Barkpark.PubSub, &1))
  end

  defp held_frames(acc \\ []) do
    receive do
      {kind, _msg} = frame when kind in [:doc_updated, :document_changed] ->
        held_frames([frame | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  for surface <- [:studio, :desk] do
    describe "#{surface}: B's frame reaches A after A's own save" do
      test "A's form keeps what the store holds, and the page is not told B's post", c do
        url = if unquote(surface) == :desk, do: c.desk, else: c.url
        a = open(c, url)
        b = open(c, url)

        hold_frames_from(a)
        send_post(b, "title", %{"title" => "Q Fixture post"})
        frames = held_frames()
        assert Enum.any?(frames, &match?({:doc_updated, _}, &1))

        send_post(a, "title", %{"title" => "Fixture post z"})
        assert stored(c)["title"] == "Fixture post z"

        Enum.each(frames, &send(a.pid, &1))
        render(a)

        assert form_of(a)["title"] == stored(c)["title"]

        refute_push_event(a, "bp:form-remote-values", %{
          values: %{"doc[title]" => %{value: "Q Fixture post"}}
        })
      end

      test "both type at once from a value A was told: both pages end on the merged text", c do
        url = if unquote(surface) == :desk, do: c.desk, else: c.url
        a = open(c, url)
        b = open(c, url)

        send_post(b, "title", %{"title" => "Fixture post 1"})
        seen = told_seq(a, "doc[title]")

        hold_frames_from(a)
        send_post(b, "title", %{"title" => "Q Fixture post 1"})
        frames = held_frames()

        send_post(a, "title", %{"title" => "Fixture post 1 z"}, %{"doc[title]" => seen})
        assert stored(c)["title"] == "Q Fixture post 1 z"

        Enum.each(frames, &send(a.pid, &1))
        render(a)
        render(b)

        assert form_of(a)["title"] == "Q Fixture post 1 z"
        assert form_of(b)["title"] == "Q Fixture post 1 z"

        refute_push_event(a, "bp:form-remote-values", %{
          values: %{"doc[title]" => %{value: "Q Fixture post 1"}}
        })
      end

      test "a field B changed and A did not still reaches A's form", c do
        url = if unquote(surface) == :desk, do: c.desk, else: c.url
        a = open(c, url)
        b = open(c, url)

        hold_frames_from(a)
        send_post(b, "day", %{"day" => "2026-02-02"})
        frames = held_frames()

        send_post(a, "title", %{"title" => "Fixture post z"})
        Enum.each(frames, &send(a.pid, &1))
        render(a)

        assert stored(c) == %{"title" => "Fixture post z", "day" => "2026-02-02"}
        assert form_of(a) == stored(c)
      end
    end
  end

  test "a frame of a save after A's last one still replaces A's form", c do
    a = open(c, c.url)
    b = open(c, c.url)

    send_post(a, "title", %{"title" => "Fixture post z"})
    send_post(b, "title", %{"title" => "Q Fixture post z"})
    render(a)

    assert form_of(a)["title"] == "Q Fixture post z"
  end

  # task-35fa42002a10445e: B saves twice before A handles anything. The list
  # frame's rebuild reads the store as it is now (B's second save), and then
  # B's first `doc_updated` frame arrives with the older text.
  test "a burst of B's saves tells A's page only the newest value", c do
    a = open(c, c.url)
    b = open(c, c.url)

    hold_frames_from(a)
    send_post(b, "title", %{"title" => "Burst one"})
    send_post(b, "title", %{"title" => "Burst two"})
    frames = held_frames()
    assert Enum.any?(frames, &match?({:doc_updated, %{doc: %{title: "Burst one"}}}, &1))

    Enum.each(frames, &send(a.pid, &1))
    render(a)

    assert form_of(a)["title"] == "Burst two"

    refute_push_event(a, "bp:form-remote-values", %{
      values: %{"doc[title]" => %{value: "Burst one"}}
    })
  end
end
