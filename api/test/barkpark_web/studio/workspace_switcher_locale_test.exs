defmodule BarkparkWeb.Studio.WorkspaceSwitcherLocaleTest do
  @moduledoc """
  task-38237bf3ee280012: in a Norwegian Studio the scope switcher's menu was
  English ("Workspace / Project / Dataset", "＋ New workspace", "Create", …),
  and its button was named "A Default Project production" by its text: the
  workspace name sat only in `title=`, which never names a button that has
  text content. The menu now reads in the Studio language, the button's
  aria-label carries the full scope, and the create inputs are labelled.
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.WorkspaceSwitcher

  @ws %{id: 1, name: "Agency Twin", slug: "agency"}
  @proj %{id: 2, name: "Default Project", slug: "default"}

  defp render_open(create_open) do
    render_component(&WorkspaceSwitcher.switcher/1,
      current_workspace: @ws,
      current_project: @proj,
      current_dataset: "production",
      menu: %{ws: @ws, proj: @proj, workspaces: [@ws], projects: [], datasets: []},
      can_create: true,
      create_open: create_open
    )
  end

  defp nb(fun), do: Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fun)

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(html, selector),
    do: html |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  test "a Norwegian menu reads Norwegian" do
    html = nb(fn -> render_open("workspace") end)

    assert texts(html, ".scope-menu-col-title") == ["Arbeidsområde", "Prosjekt", "Datasett"]

    assert ["Bytt arbeidsområde, prosjekt og datasett"] =
             html |> query("#scope-menu") |> LazyHTML.attribute("aria-label")

    assert texts(html, ".scope-menu-empty") == ["Ingen prosjekter ennå", "Ingen datasett"]
    assert ["＋ Nytt arbeidsområde", "＋ Nytt prosjekt"] = texts(html, "button.scope-menu-create")
    assert ["Opprett"] = texts(html, "button.workspace-switcher-create-submit")
    assert ["Gjeldende"] = html |> query(".scope-menu-dot") |> LazyHTML.attribute("title")

    refute html =~ ~r/>\s*(Workspace|Project|Dataset|Create|No datasets|No projects yet)\s*</
  end

  test "the button names the workspace, project and dataset" do
    for {html, prefix} <- [
          {render_open(nil), "Switch scope"},
          {nb(fn -> render_open(nil) end), "Bytt arbeidsområde"}
        ] do
      assert [label] = html |> query("button.scope-title") |> LazyHTML.attribute("aria-label")
      assert label == "#{prefix} — Agency Twin · Default Project · production"
    end
  end

  test "the create inputs carry a label, not only a placeholder" do
    workspace_html = nb(fn -> render_open("workspace") end)

    assert ["Navn på arbeidsområdet"] =
             workspace_html
             |> query("input.workspace-switcher-create-input")
             |> LazyHTML.attribute("aria-label")

    project_html =
      nb(fn ->
        render_component(&WorkspaceSwitcher.switcher/1,
          current_workspace: @ws,
          current_project: @proj,
          current_dataset: "production",
          menu: %{ws: @ws, proj: @proj, workspaces: [@ws], projects: [@proj], datasets: []},
          can_create: true,
          create_open: "project"
        )
      end)

    assert ["Prosjektnavn"] =
             project_html
             |> query("input.workspace-switcher-create-input")
             |> LazyHTML.attribute("aria-label")
  end

  test "an English menu reads as before" do
    html = render_open(nil)

    assert texts(html, ".scope-menu-col-title") == ["Workspace", "Project", "Dataset"]
    assert ["＋ New workspace", "＋ New project"] = texts(html, "button.scope-menu-create")
  end
end
