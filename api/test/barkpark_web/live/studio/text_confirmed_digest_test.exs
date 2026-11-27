defmodule BarkparkWeb.Studio.TextConfirmedDigestTest do
  @moduledoc """
  task-8a35dcc94956b8aa (#29043 review N3): a rejoined page's post is read
  as typed on the store when its confirmed digest is the store's
  (`TextConfirmed`). The digest was `:erlang.phash2/1`, 27 bits: two values
  that collide read a page typed on one as typed on the other, and its post
  was written over B's save with no banner. It is now 64 bits of sha256.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ObjectRichText
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed

  @dataset "production"
  @label "doc[meta].label"
  @t0 "one two three"
  # Two values `:erlang.phash2/1` gives the same 27-bit digest.
  @a "title 15779"
  @b "title 19776"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "digest_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "String confirmed",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "digest-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"label" => @t0}, "notes" => @a}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "string-confirmed-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "string-confirmed",
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

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    Map.put(doc.content, "title", doc.title)
  end

  # The page's `_bp_seen` as bp-array-focus.js keeps it: the form draws it,
  # the born push numbers each field, and a digest is taken with its value.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))

    seen = value |> String.replace("&quot;", ~s(")) |> Jason.decode!()
    assert_push_event(view, "bp:form-born", %{seqs: seqs, oks: oks}, 2_000)
    seen |> Map.merge(seqs) |> Map.put("v", 2) |> Map.put("ok", Map.merge(seen["ok"] || %{}, oks))
  end

  defp form_of(fields, seen) do
    %{
      "doc" => %{"title" => fields["title"] || "T0", "notes" => fields["notes"] || @a},
      @label => fields["label"] || @t0,
      "_bp_seen" => Jason.encode!(seen)
    }
  end

  defp changes(view, target, fields, seen),
    do:
      view
      |> element("#editor-form")
      |> render_change(Map.put(form_of(fields, seen), "_target", [target]))

  test "the digest is 64 bits, and the two values phash2 confuses differ" do
    assert :erlang.phash2(@a) == :erlang.phash2(@b), "the fixture no longer collides"
    assert TextConfirmed.digest(@a) =~ ~r/^[0-9a-f]{16}$/
    refute TextConfirmed.digest(@a) == TextConfirmed.digest(@b)
  end

  defp notes(c), do: stored(c)["notes"]

  for surface <- [:desk, :studio] do
    test "#{surface}: B saves a value whose old digest was A's: A's rejoined post is held, B's kept",
         c do
      # A's page shows @a, confirmed with the form; its socket drops.
      a = open(c, unquote(surface))
      seen = page(a)
      assert seen["ok"]["doc[notes]"] == TextConfirmed.digest(@a)
      GenServer.stop(a.pid, :normal)

      b = open(c, unquote(surface))
      changes(b, "doc[notes]", %{"notes" => @b}, page(b))
      assert notes(c) == @b

      # A's page typed " A7" while away and rejoins a new socket.
      a2 = open(c, unquote(surface))
      _ = page(a2)
      html = changes(a2, "doc[notes]", %{"notes" => @a <> " A7"}, seen)

      # On main the two digests matched: A's words were written over B's.
      assert notes(c) == @b, "A's post was written over B's save"
      assert html =~ "doc-conflict-banner", "A was not held"
    end

    test "#{surface}: control: nobody else saved: A's rejoined post is written", c do
      a = open(c, unquote(surface))
      seen = page(a)
      GenServer.stop(a.pid, :normal)
      a2 = open(c, unquote(surface))
      _ = page(a2)
      html = changes(a2, "doc[notes]", %{"notes" => @a <> " A7"}, seen)
      assert notes(c) == @a <> " A7"
      refute html =~ "doc-conflict-banner"
    end
  end
end
