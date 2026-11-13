defmodule BarkparkWeb.Studio.TwoEditorsSameFieldTest do
  @moduledoc """
  task-35956a566dd2c862: two people type in the same free-text field.

  A person typing in the title could not take another editor's save (the
  page keeps typing it has not sent), so their next post was written from an
  older value than the store held, and it replaced the other's words. The
  page now reports, in the hidden `_bp_seen` input, the number of the last
  value each field showed (`RemoteValues`, bp-array-focus.js); the server
  merges the post onto the stored text from that value.

  The tests post `_bp_seen` as bp-array-focus.js writes it (host test
  `__form_remote_values.test.mjs`): the new number when the field shows the
  pushed value, the old one when the person was typing.

  The review of #25908 (review-25908.md) found two ways the first merge went
  wrong: dates and selects were spliced, and words a person deleted came
  back. Those are tests here too, and so is the size bound.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "sf_post_#{n}"
    doc_id = "sf-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "SF posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "day", "title" => "Day", "type" => "date"},
            %{
              "name" => "stage",
              "title" => "Stage",
              "type" => "string",
              "options" => %{"list" => ["draft", "review", "published"]}
            },
            %{"name" => "site", "title" => "Site", "type" => "url"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Fixture post",
          "content" => %{
            "excerpt" => "First",
            "day" => "2026-01-01",
            "stage" => "draft",
            "site" => "https://old.example"
          }
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "same-field-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "same-field", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     url: "#{base}/#{type}/#{doc_id}",
     desk: "#{base}/_desk/#{type};#{doc_id}",
     type: type,
     doc_id: doc_id}
  end

  defp open(c, url \\ nil) do
    {:ok, view, _html} = live(c.conn, url || c.url)
    view
  end

  defp form_of(view) do
    :sys.get_state(view.pid).socket.assigns.editor_form
    |> Map.take(["title", "excerpt", "day", "stage", "site"])
  end

  # What the browser posts: the whole form as the page shows it, `_target`
  # naming the field typed in, and `_bp_seen` as bp-array-focus.js keeps it.
  defp send_post(view, target, changes, seen \\ %{}) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form_of(view), changes),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # The push the page gets for another editor's save, as {values, seqs}.
  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: values} = payload)
    {values, Map.get(payload, :seqs, %{})}
  end

  # The number bp-array-focus.js reports for a field: the old value's when the
  # person was typing (`:was`), the new one's when the field shows it (`:new`).
  # nil when the push carried none.
  defp seq(seqs, name, which) do
    case {Map.get(seqs, name), which} do
      {[was, _new], :was} -> was
      {[_was, new], :new} -> new
      _ -> nil
    end
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(Map.take(doc.content || %{}, ["excerpt", "day", "stage", "site"]), "title", doc.title)
  end

  describe "a post typed from an older value than the store holds" do
    test "keeps both people's words, from the value the page reports", c do
      a = open(c)
      b = open(c)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      {_values, seqs} = told(a)
      was_seq = seq(seqs, "doc[title]", :was)

      # A was typing, so the title still shows A's text: the page reports the
      # value it was typed from.
      send_post(a, "title", %{"title" => "Fixture post A7"}, %{"doc[title]" => was_seq})

      assert stored(c)["title"] == "Fixture post B3 A7"

      # A's page is told the stored text, and its form holds it.
      assert_push_event(a, "bp:form-remote-values", %{values: values})
      assert values["doc[title]"] == %{value: "Fixture post B3 A7", was: "Fixture post A7"}
      assert form_of(a)["title"] == "Fixture post B3 A7"
    end

    test "A's own landed post is its base until it shows a later value", c do
      a = open(c)
      b = open(c)

      send_post(a, "title", %{"title" => "Fixture post A5"})
      render(b)
      send_post(b, "title", %{"title" => "Fixture post A5 B3"})
      {_values, seqs} = told(a)
      was_seq = seq(seqs, "doc[title]", :was)

      send_post(a, "title", %{"title" => "Fixture post A5 A7"}, %{"doc[title]" => was_seq})

      assert stored(c)["title"] == "Fixture post A5 B3 A7"
    end

    test "a third writer that lands before A's post is merged in too", c do
      a = open(c)
      b = open(c)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      {_values, seqs} = told(a)
      new_seq = seq(seqs, "doc[title]", :new)

      {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)

      {:ok, _, _} =
        Content.upsert_draft(doc, c.type, nil, %{"title" => "Fixture post B3 C9"}, @dataset)

      send_post(a, "title", %{"title" => "Fixture post B3 A7"}, %{"doc[title]" => new_seq})

      assert stored(c)["title"] == "Fixture post B3 C9 A7"
    end

    test "on the desk too", c do
      a = open(c, c.desk)
      b = open(c, c.desk)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      {_values, seqs} = told(a)
      was_seq = seq(seqs, "doc[title]", :was)
      send_post(a, "title", %{"title" => "Fixture post A7"}, %{"doc[title]" => was_seq})

      assert stored(c)["title"] == "Fixture post B3 A7"
    end

    test "a page that reports nothing for the field is not merged (as before)", c do
      a = open(c)
      b = open(c)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      told(a)
      send_post(a, "title", %{"title" => "Fixture post A7"})

      assert stored(c)["title"] == "Fixture post A7"
    end
  end

  describe "the review-25908 regressions" do
    for surface <- [:studio, :desk] do
      test "a date, a select and a url take the value picked, never a splice (#{surface})", c do
        url = if unquote(surface) == :desk, do: c.desk, else: c.url
        a = open(c, url)
        b = open(c, url)

        send_post(b, "day", %{
          "day" => "2026-02-15",
          "stage" => "published",
          "site" => "https://b.example"
        })

        {values, seqs} = told(a)
        assert Map.has_key?(values, "doc[day]")
        assert seqs == %{}, "only free-text fields are numbered"

        # Even a page claiming it last saw the oldest values gets no splice.
        seen = %{"doc[day]" => 0, "doc[stage]" => 0, "doc[site]" => 0}
        send_post(a, "day", %{"day" => "2026-01-20"}, seen)
        send_post(a, "stage", %{"stage" => "review"}, seen)
        send_post(a, "site", %{"site" => "https://a.example/x"}, seen)

        assert Map.take(stored(c), ["day", "stage", "site"]) == %{
                 "day" => "2026-01-20",
                 "stage" => "review",
                 "site" => "https://a.example/x"
               }
      end
    end

    test "A deletes B's words: the deletion stays, on a second post too", c do
      a = open(c)
      b = open(c)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      {_values, seqs} = told(a)
      new_seq = seq(seqs, "doc[title]", :new)
      seen = %{"doc[title]" => new_seq}

      send_post(a, "title", %{"title" => "Fixture post!"}, seen)
      assert stored(c)["title"] == "Fixture post!"

      send_post(a, "title", %{"title" => "Fixture post!"}, seen)
      assert stored(c)["title"] == "Fixture post!"

      send_post(a, "title", %{"title" => "Fixture post!!"}, seen)
      assert stored(c)["title"] == "Fixture post!!"

      send_post(a, "title", %{"title" => "Fixture post?"}, seen)
      assert stored(c)["title"] == "Fixture post?"
    end

    test "replacing the whole title after seeing B's save stores the new title", c do
      a = open(c)
      b = open(c)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      {_values, seqs} = told(a)
      new_seq = seq(seqs, "doc[title]", :new)

      send_post(a, "title", %{"title" => "New title"}, %{"doc[title]" => new_seq})

      assert stored(c)["title"] == "New title"
    end

    test "a number the server never sent picks no base", c do
      a = open(c)
      b = open(c)

      send_post(b, "title", %{"title" => "Fixture post B3"})
      told(a)
      send_post(a, "title", %{"title" => "Fixture post A7"}, %{"doc[title]" => -5})

      assert stored(c)["title"] == "Fixture post A7"
    end
  end

  test "above the size bound the post stands as sent (last post wins), and the save is fast",
       c do
    # 72 KB: above TextRebase's 64 KB bound.
    big = String.duplicate("lorem ipsum ", 6_000)
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    {:ok, _, _} = Content.upsert_draft(doc, c.type, nil, %{"excerpt" => big}, @dataset)

    a = open(c)
    b = open(c)

    send_post(b, "excerpt", %{"excerpt" => "B " <> big})
    {_values, seqs} = told(a)
    was_seq = seq(seqs, "doc[excerpt]", :was)

    {us, _} =
      :timer.tc(fn ->
        send_post(a, "excerpt", %{"excerpt" => big <> " A"}, %{"doc[excerpt]" => was_seq})
      end)

    assert stored(c)["excerpt"] == big <> " A"
    assert us < 2_000_000
  end
end
