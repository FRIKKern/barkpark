defmodule BarkparkWeb.Studio.StudioLiveInspectorPrefTest do
  @moduledoc """
  spd-b1-pane-state-persistence — the SERVER half of the remembered inspector
  collapse.

  The client half lives in root.html.heex: the pre-paint head block stamps
  `data-inspector-pref="closed"` on <html> from localStorage
  (`barkpark_inspector`), the painted-closed rule paints the strip at first
  paint, and the body script sends the same fact as the `inspector_closed`
  connect param. What is pinned here:

    1. The static render is NOT seeded — connect_params is nil there, so the
       server still renders `.is-open` and first paint stays CSS-owned.
    2. The connected mount IS seeded — `inspector_closed: true` renders
       `.is-collapsed`, and the seed survives the per-paper reseed.
    3. The PER-BUCKET DECISION. Only a toggle at `wide` is remembered (it
       pushes `inspector-pref`). Below `wide` a toggle pushes nothing, because
       the default there is already painted-closed and an open is a per-visit
       summon (D91). Only "closed" is ever stored, so no stored value can make
       a narrow/phone reload paint the Tier-3 summoned destination.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-09-23-spd-b1-inspector-pref"
  @slug2 "2026-09-23-spd-b1-inspector-pref-two"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for slug <- [@slug, @slug2] do
      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: @dataset,
            blocks: [
              %{"id" => "h-1", "type" => "heading", "text" => "Inspector Pref"},
              %{
                "id" => "p-1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "The remembered strip."}]
              }
            ]
          })
        )
    end

    :ok
  end

  defp path(slug \\ @slug), do: scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")

  defp with_pref(conn), do: put_connect_params(conn, %{"inspector_closed" => true})

  defp aside_tag(html) do
    case Regex.run(~r/<aside[^>]*data-test-id="paper-metadata-sidebar"[^>]*>/, html) do
      [tag] -> tag
      nil -> flunk("the document inspector <aside> did not render at all")
    end
  end

  # By id, not data-test-id: at narrow/phone the summoned destination renames
  # the same button `sidebar-dismiss` (D167), and it still fires the toggle.
  defp toggle(view), do: element(view, "#bp-doc-sidebar-toggle") |> render_click()

  describe "seeding happens only at connected mount" do
    test "the STATIC render ignores the preference — first paint is CSS-owned", %{conn: conn} do
      # A plain GET is the static render: no socket, no connect_params. It must
      # render exactly the default, so the only thing that can paint the strip
      # at first paint is the cascade keyed on the pre-paint stamp.
      html = conn |> with_pref() |> get(path()) |> html_response(200)
      tag = aside_tag(html)

      assert tag =~ "bp-doc-sidebar is-open"
      refute tag =~ "data-user-opened"
    end

    test "the CONNECTED mount seeds the collapse from connect_params", %{conn: conn} do
      {:ok, _view, html} = conn |> with_pref() |> live(path())
      tag = aside_tag(html)

      assert tag =~ "bp-doc-sidebar is-collapsed"
      refute tag =~ "data-user-opened"
      refute html =~ ~s(id="bp-doc-sidebar-body")
    end

    test "control: with no preference the connected mount is the unchanged default", %{conn: conn} do
      {:ok, _view, html} = live(conn, path())
      assert aside_tag(html) =~ "bp-doc-sidebar is-open"
    end

    test "a truthy-but-not-true param is not a preference", %{conn: conn} do
      {:ok, _view, html} =
        conn |> put_connect_params(%{"inspector_closed" => "false"}) |> live(path())

      assert aside_tag(html) =~ "bp-doc-sidebar is-open"
    end

    test "the seed survives opening another paper (the per-paper reseed reads it)", %{conn: conn} do
      {:ok, view, _html} = conn |> with_pref() |> live(path())
      html = render_patch(view, path(@slug2))
      assert aside_tag(html) =~ "bp-doc-sidebar is-collapsed"
    end
  end

  describe "wide — the toggle is remembered" do
    test "collapsing pushes closed: true; reopening pushes closed: false", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_hook(view, "width-bucket", %{"bucket" => "wide"})

      assert aside_tag(toggle(view)) =~ "is-collapsed"
      assert_push_event(view, "inspector-pref", %{closed: true})

      assert aside_tag(toggle(view)) =~ "is-open"
      assert_push_event(view, "inspector-pref", %{closed: false})
    end

    test "after a wide collapse the next paper opens collapsed in the same session", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      toggle(view)
      assert aside_tag(render_patch(view, path(@slug2))) =~ "is-collapsed"
    end

    test "a remembered collapse reopens with ONE press at wide", %{conn: conn} do
      {:ok, view, _html} = conn |> with_pref() |> live(path())
      assert aside_tag(toggle(view)) =~ "bp-doc-sidebar is-open"
      assert_push_event(view, "inspector-pref", %{closed: false})
    end
  end

  describe "below wide — the per-bucket decision" do
    for bucket <- ~w(standard narrow phone) do
      @bucket bucket

      test "#{bucket}: a toggle is a per-visit summon and is NOT remembered", %{conn: conn} do
        {:ok, view, _html} = live(conn, path())
        render_hook(view, "width-bucket", %{"bucket" => @bucket})

        opened = toggle(view)
        assert aside_tag(opened) =~ "data-user-opened"
        refute_push_event(view, "inspector-pref", %{closed: _}, 50)

        toggle(view)
        refute_push_event(view, "inspector-pref", %{closed: _}, 50)
      end

      test "#{bucket}: a stored preference never paints a panel the user did not ask for",
           %{conn: conn} do
        {:ok, view, _html} = conn |> with_pref() |> live(path())
        html = render_hook(view, "width-bucket", %{"bucket" => @bucket})
        tag = aside_tag(html)

        # The summoned destination and the standard dock both key on
        # `[data-user-opened]`; a reload must not carry it.
        refute tag =~ "data-user-opened"
        refute tag =~ "data-inspector-destination"

        # And one press still opens it — the same result as the painted-closed
        # default's first press, so the preference costs no extra click.
        assert aside_tag(toggle(view)) =~ "data-user-opened"
      end
    end
  end
end
