defmodule BarkparkWeb.Admin.PluginsUrlScopeInertTest do
  @moduledoc """
  task-8cf8d0fb792da9e3, item 1: the plugins admin pages sit under
  `/w/:ws/p/:proj/d/:dataset/studio/_plugins` with no `ResolveWorkspace` and no
  `LiveScope`. That is safe only while the URL's scope is inert there: the
  page is the instance-wide plugin registry, and the workspace, project and
  dataset segments are echoed into links and one label, never looked up.

  These tests pin that. If either page starts reading the workspace or the
  dataset named in the URL, it needs the membership gate and the dataset
  fence first, and these go red.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Tenancy}

  @own "bound-own"
  @other "bound-other"
  @foreign_name "FOREIGN-WORKSPACE-NAME"
  @foreign_project "foreign-second-project"
  @foreign_dataset "foreign-only-dataset"

  setup %{conn: conn} do
    home = create_workspace!("plugins-home-#{System.unique_integer([:positive])}")
    home_proj = create_project!(home, "default")
    for ds <- [@own, @other], do: {:ok, _} = Tenancy.get_or_create_dataset(home_proj, ds)

    {:ok, foreign} =
      Tenancy.create_workspace(%{
        slug: "plugins-foreign-#{System.unique_integer([:positive])}",
        name: @foreign_name
      })

    create_project!(foreign, "default")
    second = create_project!(foreign, @foreign_project)
    {:ok, _} = Tenancy.get_or_create_dataset(second, @foreign_dataset)

    # An admin seat in `home` only, bound to one of its datasets.
    raw = "plugins-inert-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "plugins inert", @own, ["read", "write", "admin"], home.id,
        dataset_bound: true
      )

    {:ok, conn: init_test_session(conn, %{"api_token" => raw}), home: home, foreign: foreign}
  end

  defp plugins(ws_slug, dataset), do: "/w/#{ws_slug}/p/default/d/#{dataset}/studio/_plugins"

  defp workspace_of(view), do: :sys.get_state(view.pid).socket.assigns[:current_workspace]

  # The rendered page with the caller's own URL segments blanked, so two
  # mounts can be compared on everything the server chose to show.
  defp page(view, segments) do
    view |> render() |> without(segments)
  end

  defp without(html, segments) do
    segments
    |> Enum.reduce(html, &String.replace(&2, &1, "·"))
    |> String.replace(~r/phx-[A-Za-z0-9_-]{8,}/, "phx-id")
    |> String.replace(~r/data-phx-(session|static)="[^"]*"/, "")
    |> String.replace(~r/(name="_csrf_token"[^>]*value=")[^"]*/, "\\1")
  end

  test "the dataset segment changes the label and the links, nothing else", ctx do
    {:ok, own, _} = live(ctx.conn, plugins(ctx.home.slug, @own))
    {:ok, other, _} = live(ctx.conn, plugins(ctx.home.slug, @other))

    assert render(other) =~ "plugins-admin"
    assert page(own, [@own]) == page(other, [@other])
    assert workspace_of(other).id == ctx.home.id
  end

  test "a workspace the caller has no seat in is never resolved from the URL", ctx do
    {:ok, home_view, _} = live(ctx.conn, plugins(ctx.home.slug, @own))
    {:ok, view, _} = live(ctx.conn, plugins(ctx.foreign.slug, @own))
    html = render(view)

    # The chrome stays on the caller's own workspace.
    assert workspace_of(view).id == ctx.home.id
    assert page(home_view, [ctx.home.slug]) == without(html, [ctx.foreign.slug, ctx.home.slug])

    # With the scope menu open, nothing of the foreign workspace is listed.
    opened = render_click(view, "scope-menu-toggle", %{})
    assert opened != html

    for secret <- [@foreign_name, @foreign_project, @foreign_dataset],
        do: refute(opened =~ secret)

    assert without(render_click(home_view, "scope-menu-toggle", %{}), [ctx.home.slug]) ==
             without(opened, [ctx.foreign.slug, ctx.home.slug])
  end

  test "a workspace slug that names nothing answers the same page (no existence oracle)", ctx do
    missing = "plugins-missing-#{System.unique_integer([:positive])}"

    {:ok, real, _} = live(ctx.conn, plugins(ctx.foreign.slug, @own))
    {:ok, none, _} = live(ctx.conn, plugins(missing, @own))

    assert page(real, [ctx.foreign.slug]) == page(none, [missing])
  end

  test "plugin settings: the dataset and workspace segments are echoed, never read", ctx do
    path = fn ws, ds -> plugins(ws, ds) <> "/onixedit/settings" end

    {:ok, own, _} = live(ctx.conn, path.(ctx.home.slug, @own))
    {:ok, view, _} = live(ctx.conn, path.(ctx.foreign.slug, @other))

    assert workspace_of(view).id == ctx.home.id

    assert page(own, [ctx.home.slug, @own]) ==
             page(view, [ctx.foreign.slug, ctx.home.slug, @other])

    refute render(view) =~ @foreign_name
  end
end
