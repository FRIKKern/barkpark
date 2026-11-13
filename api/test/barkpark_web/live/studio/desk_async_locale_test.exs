defmodule BarkparkWeb.Studio.DeskAsyncLocaleTest do
  @moduledoc """
  A pane is read in a task (`start_async`), and a task has no Gettext locale
  of its own: in an nb-NO workspace the notes a read builds came out English
  ("No documents here yet."), seen on guerrilla 2026-11-11. Every read task,
  the pane's own, its next page and a hovered row's warm read, now renders in
  the page's locale. The root pane's fallback title ("Content", as the
  TanStack Studio's) is Barkpark's word, so it is translated too.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.PaneComponent

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    empty = "loc_empty_#{n}"
    full = "loc_full_#{n}"

    for type <- [empty, full] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Loc #{type}",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset
        )
    end

    doc = "loc-doc-#{n}"
    {:ok, _} = Content.create_document(full, %{"doc_id" => doc, "title" => "One"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), "nb-NO")

    raw = "desk-loc-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-loc", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, empty: empty, full: full, doc: doc}
  end

  # Every read says which locale its task renders in; a list says it has
  # another page, so the pane can be asked for it.
  defp record_reads do
    test = self()

    Application.put_env(:barkpark, PaneComponent,
      reader: fn pane, node, dataset, scope, title ->
        send(
          test,
          {:read_locale, pane.kind, pane[:query] != nil, Gettext.get_locale(BarkparkWeb.Gettext)}
        )

        read = PaneComponent.read(pane, node, dataset, scope, title)
        if pane.kind == :list, do: Map.put(read, :more?, true), else: read
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)
  end

  test "an empty list in an nb-NO workspace says so in Norwegian", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.empty}")
    render_async(view, 5_000)

    note = view |> element(~s([data-pane-index="1"])) |> render()

    assert note =~ "Ingen dokumenter her ennå.",
           "the list pane says: " <> String.slice(note, 0, 600)

    refute note =~ "No documents here yet."
  end

  test "the root pane's fallback title is Norwegian", c do
    {:ok, view, _html} = live(c.conn, c.base)
    render_async(view, 5_000)

    assert has_element?(view, ~s([data-pane-index="0"][aria-label="Innhold"])),
           "root pane: " <>
             (view |> element(~s([data-pane-index="0"])) |> render() |> String.slice(0, 300))
  end

  test "the pane's read, its next page and a warm read all run in the page's locale", c do
    record_reads()

    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.full}")
    render_async(view, 5_000)

    view
    |> element(~s([data-pane-index="1"] [role="list"][phx-viewport-bottom="more"]))
    |> render_hook("more", %{})

    render_async(view, 5_000)

    view
    |> element("#desk-panes")
    |> render_hook("warm", %{"href" => "#{c.base}/#{c.full};#{c.doc}"})

    render_async(view, 5_000)
    Process.sleep(200)

    reads = collect([])
    kinds = Enum.map(reads, fn {kind, more?, _} -> {kind, more?} end)
    assert {:doc, false} in kinds, "no warm read was recorded: #{inspect(reads)}"
    assert Enum.count(kinds, &(&1 == {:list, true})) >= 2, "no next-page read: #{inspect(reads)}"
    assert Enum.all?(reads, fn {_, _, locale} -> locale == "nb_NO" end), inspect(reads)
  end

  defp collect(acc) do
    receive do
      {:read_locale, kind, query?, locale} -> collect([{kind, query?, locale} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
