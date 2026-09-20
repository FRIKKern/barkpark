defmodule BarkparkWeb.Studio.WorkspaceSwitcherTest do
  @moduledoc """
  Pins the rendering logic of WorkspaceSwitcher:
    - name_of/1: renders the PROJECT trail (`span.scope-title-trail`) — the
      project's name, or an em-dash when no project resolves. It is NOT what
      renders the workspace: the title bar shows the workspace through
      `initial_of/1` in `span.scope-avatar` plus the button's `title=` hint.
    - initial_of/1: the workspace avatar letter (`span.scope-avatar`)
    - same?/2: drives is-current / is-previewed CSS classes on menu items
    - current_dataset?/3: drives the dataset dot (only when previewed ws+proj
      match the current ws+proj AND the slug matches)
    - closed state (menu: nil) renders no popover
    - can_create gate hides / shows the "+ New workspace" affordance
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.WorkspaceSwitcher

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws(id, name), do: %{id: id, name: name, slug: "ws-#{id}"}
  defp proj(id, name), do: %{id: id, name: name, slug: "proj-#{id}"}
  defp ds(slug, name \\ nil), do: %{slug: slug, name: name || slug}

  # Bind an assertion to the ELEMENT that carries it. Every claim below used to
  # be a substring search over the whole render, which is satisfied by any
  # render that emits the character or class ANYWHERE — including renders that
  # put it on every row, or on exactly the wrong one.
  defp frag(html), do: LazyHTML.from_fragment(html)

  defp text_of(html, selector) do
    html |> frag() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp ws_button(html, %{id: id}) do
    html
    |> frag()
    |> LazyHTML.query(~s(button[phx-click="scope-menu-ws"][phx-value-id="#{id}"]))
  end

  defp ws_classes(html, w) do
    html
    |> ws_button(w)
    |> LazyHTML.attribute("class")
    |> List.first()
    |> Kernel.||("")
    |> String.split()
  end

  defp ws_has_dot?(html, w) do
    html |> ws_button(w) |> LazyHTML.query("span.scope-menu-dot") |> Enum.count() > 0
  end

  defp render_switcher(overrides \\ []) do
    defaults = [
      current_workspace: nil,
      current_project: nil,
      current_dataset: nil,
      menu: nil,
      can_create: false,
      create_open: nil
    ]

    render_component(&WorkspaceSwitcher.switcher/1, Keyword.merge(defaults, overrides))
  end

  # ---------------------------------------------------------------------------
  # name_of/1 — via title-bar spans
  # ---------------------------------------------------------------------------

  describe "name_of — the project trail (span.scope-title-trail)" do
    # `name_of/1` has exactly one visible subject in this component: the
    # PROJECT trail at `span.scope-title-trail`. Asserting `html =~ "—"` could
    # never see it — the literal em-dash is also emitted by `scope_hint/3`
    # ("Switch scope — …") and by `span.scope-dataset-badge` (`@current_dataset
    # || "—"`), both on EVERY render, so the assertion held no matter what
    # `name_of/1` returned.

    test "shows the project name when a project is set" do
      html = render_switcher(current_project: proj(7, "Widgets"))
      assert text_of(html, "span.scope-title-trail") == "Widgets"
    end

    test "falls back to an em-dash when no project resolves" do
      html = render_switcher(current_project: nil)
      assert text_of(html, "span.scope-title-trail") == "—"
    end

    test "falls back to an em-dash when the project map has no name key" do
      html = render_switcher(current_project: %{id: 99})
      assert text_of(html, "span.scope-title-trail") == "—"
    end
  end

  # ---------------------------------------------------------------------------
  # initial_of/1 — the workspace avatar, which is what actually shows the
  # workspace in the title bar (name_of/1 never touches it)
  # ---------------------------------------------------------------------------

  describe "initial_of — the workspace avatar (span.scope-avatar)" do
    test "shows the workspace's upcased initial when set" do
      html = render_switcher(current_workspace: ws(1, "acme"))
      assert text_of(html, "span.scope-avatar") == "A"
      # …and the full name rides the button's tooltip, which is the only place
      # it appears at all.
      assert [hint] =
               html
               |> frag()
               |> LazyHTML.query("button.scope-title")
               |> LazyHTML.attribute("title")

      assert hint =~ "acme"
    end

    test "falls back to the brand letter when no workspace resolves" do
      assert text_of(render_switcher(current_workspace: nil), "span.scope-avatar") == "B"
      assert text_of(render_switcher(current_workspace: %{id: 99}), "span.scope-avatar") == "B"
    end
  end

  # ---------------------------------------------------------------------------
  # closed-menu state
  # ---------------------------------------------------------------------------

  describe "switcher with menu: nil (closed)" do
    test "does not render the scope-menu popover" do
      html = render_switcher()
      refute html =~ ~s(class="scope-menu")
      refute html =~ "scope-menu-col"
    end

    test "aria-expanded is false when closed" do
      html = render_switcher()
      assert html =~ ~s(aria-expanded="false")
    end
  end

  # ---------------------------------------------------------------------------
  # same?/2 — is-current / is-previewed CSS on workspace items
  # ---------------------------------------------------------------------------

  describe "same? — CSS class on menu items" do
    setup do
      ws_a = ws(1, "Alpha")
      ws_b = ws(2, "Beta")

      menu = %{
        ws: ws_a,
        proj: nil,
        workspaces: [ws_a, ws_b],
        projects: [],
        datasets: []
      }

      %{ws_a: ws_a, ws_b: ws_b, menu: menu}
    end

    test "is-current applied to the active workspace item", %{ws_a: ws_a, ws_b: ws_b, menu: menu} do
      html = render_switcher(current_workspace: ws_a, menu: menu)
      assert "is-current" in ws_classes(html, ws_a)
      refute "is-current" in ws_classes(html, ws_b)
    end

    # CLASS only. Disjoint from the dot test below, so that marking every row
    # current and showing the dot on every row are two separately-measured
    # defects rather than one.
    test "non-current workspace does not get is-current class", %{
      ws_a: ws_a,
      ws_b: ws_b,
      menu: menu
    } do
      # current = ws_b; previewed (menu.ws) = ws_a — so ws_a is previewed but
      # NOT current, and must not be dressed as the place the operator is.
      html = render_switcher(current_workspace: ws_b, menu: menu)

      assert ws_classes(html, ws_a) != [], "ws_a's menu button did not render at all"

      refute "is-current" in ws_classes(html, ws_a),
             "a non-current workspace was marked is-current: #{inspect(ws_classes(html, ws_a))}"

      assert "is-current" in ws_classes(html, ws_b)
    end

    # DOT only — the other half of "this row is where you are", and the half a
    # class assertion cannot see.
    test "only the current workspace carries the Current dot", %{
      ws_a: ws_a,
      ws_b: ws_b,
      menu: menu
    } do
      html = render_switcher(current_workspace: ws_b, menu: menu)

      assert ws_has_dot?(html, ws_b), "the current workspace lost its Current dot"

      refute ws_has_dot?(html, ws_a),
             "a non-current workspace shows the Current dot"
    end

    test "is-previewed applied to the previewed (but not current) workspace", %{
      ws_a: ws_a,
      ws_b: ws_b,
      menu: menu
    } do
      # current = ws_b, previewed = ws_a
      html = render_switcher(current_workspace: ws_b, menu: menu)
      assert "is-previewed" in ws_classes(html, ws_a)
      refute "is-previewed" in ws_classes(html, ws_b)
    end

    test "aria-expanded is true when menu is open", %{menu: menu} do
      html = render_switcher(menu: menu)
      assert html =~ ~s(aria-expanded="true")
    end
  end

  # ---------------------------------------------------------------------------
  # current_dataset?/3 — dataset dot only when ws+proj+slug all match
  # ---------------------------------------------------------------------------

  describe "current_dataset? — dataset dot behaviour" do
    setup do
      w = ws(10, "MyWS")
      p = proj(20, "MyProj")

      menu = %{
        ws: w,
        proj: p,
        workspaces: [w],
        projects: [p],
        datasets: [ds("staging"), ds("production")]
      }

      %{w: w, p: p, menu: menu}
    end

    test "shows dot on the matching dataset when ws+proj+slug match", %{w: w, p: p, menu: menu} do
      html =
        render_switcher(
          current_workspace: w,
          current_project: p,
          current_dataset: "production",
          menu: menu
        )

      # The dot span appears for the current dataset
      assert html =~ ~s(title="Current")
    end

    test "no dot when dataset slug does not match", %{w: w, p: p, menu: menu} do
      html =
        render_switcher(
          current_workspace: w,
          current_project: p,
          current_dataset: "other",
          menu: menu
        )

      # Both dataset buttons must render
      assert html =~ ~s(phx-value-ds="staging")
      assert html =~ ~s(phx-value-ds="production")
      # Neither dataset button should carry the is-current class
      # (dataset buttons are identified by phx-click="scope-open")
      # Split on scope-open button occurrences and check none have is-current
      dataset_buttons = html |> String.split("phx-click=\"scope-open\"") |> tl()

      Enum.each(dataset_buttons, fn btn ->
        refute btn =~ "is-current"
      end)
    end

    test "no dot when previewed workspace differs from current workspace", %{p: p, menu: menu} do
      other_ws = ws(99, "OtherWS")
      # previewed ws (w/id=10) differs from current ws (other_ws/id=99)
      html =
        render_switcher(
          current_workspace: other_ws,
          current_project: p,
          current_dataset: "production",
          menu: menu
        )

      assert html =~ ~s(phx-value-ds="production")
      # Dataset buttons must not be marked is-current
      dataset_buttons = html |> String.split("phx-click=\"scope-open\"") |> tl()

      Enum.each(dataset_buttons, fn btn ->
        refute btn =~ "is-current"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # can_create gate
  # ---------------------------------------------------------------------------

  describe "can_create gate" do
    setup do
      w = ws(1, "WS")

      menu = %{
        ws: w,
        proj: nil,
        workspaces: [w],
        projects: [],
        datasets: []
      }

      %{w: w, menu: menu}
    end

    test "create affordance hidden when can_create is false", %{menu: menu} do
      html = render_switcher(menu: menu, can_create: false)
      refute html =~ "New workspace"
    end

    test "create affordance shown when can_create is true", %{menu: menu} do
      html = render_switcher(menu: menu, can_create: true)
      assert html =~ "New workspace"
    end
  end
end
