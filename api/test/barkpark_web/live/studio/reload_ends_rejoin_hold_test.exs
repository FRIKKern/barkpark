defmodule BarkparkWeb.Studio.ReloadEndsRejoinHoldTest do
  # task-2e9aaa937cfc3da1 (#28840 review, R3): Reload ends a rejoin hold.
  # The server's form became the stored string, but A's page was never sent
  # it: a patch leaves a focused input alone, and Reload repainted only rich
  # text. A's next key wrote A's words over B's, with no banner.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ObjectRichText

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])
  @label "doc[meta].label"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "reload_rejoin_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "String race",
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

    id = "reload-rejoin-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"label" => "one two three"}, "notes" => "one two three"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "string-race-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "string-race", @dataset, ~w(read write admin), ws_id)
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

  # A post as the page sends it, `_bp_seen` as bp-array-focus.js keeps it.
  defp posts(view, target, fields) do
    view
    |> element("#editor-form")
    |> render_change(
      Map.merge(
        %{
          "_target" => [target],
          "doc" => %{"title" => "T0", "notes" => fields["notes"] || "one two three"},
          @label => fields["label"] || "one two three",
          "_bp_seen" => Jason.encode!(%{"v" => 2})
        },
        Map.take(fields, ["doc"])
      )
    )
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp born(view, name) do
    assert_push_event(view, "bp:form-born", %{seqs: %{^name => _}}, 2_000)
    # The page shows A's typing, not the stored value: it reports 0.
    0
  end

  defp posts_seen(view, target, fields, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => "T0", "notes" => "one two three"},
      @label => fields["label"],
      "_bp_seen" => Jason.encode!(Map.put(seen, "v", 2))
    })
  end

  defp saves(view, label, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "notes" => "one two three"},
      @label => label,
      "_bp_seen" => Jason.encode!(Map.put(seen, "v", 2))
    })
  end

  defp label(c), do: get_in(stored(c), ["meta", "label"])

  # A rejoin hold on the label; A Saves while B writes the label inside;
  # A presses Reload.
  defp reloaded(c, surface) do
    b = open(c, surface)
    posts(b, @label, %{"label" => "one twB three"})

    a = open(c, surface)
    n = born(a, @label)

    ObjectRichText.inside(
      a,
      fn -> posts(b, @label, %{"label" => "one twBB three"}) end,
      fn -> saves(a, "one twA three", %{@label => n}) end
    )

    assert has_element?(a, @banner)
    drain(a)
    render_hook(a, "reload-remote-doc", %{})
    refute has_element?(a, @banner)
    assert label(c) == "one twBB three"
    {a, n}
  end

  defp drain(view) do
    {ref, _, _} = view.proxy

    receive do
      {^ref, {:push_event, _, _}} -> drain(view)
    after
      300 -> :ok
    end
  end

  for surface <- [:desk, :studio] do
    test "#{surface}: Reload ends a rejoin hold and sends the page the stored label with its number",
         c do
      {a, _n} = reloaded(c, unquote(surface))

      # On main: no push; the focused input kept A's words.
      assert_push_event(
        a,
        "bp:form-remote-values",
        %{
          values: %{@label => %{value: "one twBB three", was: "one twA three"}},
          seqs: %{@label => [_, seq]}
        },
        2_000
      )

      # The page drew it and types on: written as sent, onto B's words.
      posts_seen(a, @label, %{"label" => "one twBB threeX"}, %{@label => seq})
      assert ObjectRichText.eventually(fn -> label(c) == "one twBB threeX" end)
      refute has_element?(a, @banner)
    end

    test "#{surface}: after Reload, a key from a page still on A's words never writes them over B's",
         c do
      {a, n} = reloaded(c, unquote(surface))

      # On main: stored "one twA threeX", no banner.
      posts_seen(a, @label, %{"label" => "one twA threeX"}, %{@label => n})
      assert label(c) == "one twBB three"
      # Read as a rejoin post: held, with the banner, A's words in the form.
      assert has_element?(a, @banner)
      assert get_in(assigns(a).editor_form, ["meta", "label"]) == "one twA threeX"
    end
  end
end
