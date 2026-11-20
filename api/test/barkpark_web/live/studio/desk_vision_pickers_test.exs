defmodule BarkparkWeb.Studio.DeskVisionPickersTest do
  @moduledoc """
  The desk's Vision picks its dataset and API version, as TanStack's (J37,
  `vision-saved.spec.ts`). The datasets are the page's project's only: a
  dataset of another workspace, or of another project of this one, is never
  listed; a dataset-bound token's others are greyed. The query itself runs in
  the browser (`bp-desk-vision.js`, `__desk_vision.test.mjs`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    workspace = Tenancy.get_default_workspace()
    tag = System.unique_integer([:positive])

    {:ok, _} =
      Tenancy.create_dataset(proj.id, %{slug: "dvp-staging-#{tag}", name: "Staging #{tag}"})

    # Workspace B, and another project of A: neither's datasets are this page's.
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)
    {:ok, _} = Tenancy.create_dataset(proj_b.id, %{slug: "dvp-b-secret-#{tag}", name: "B secret"})
    proj_a2 = TenancyFixtures.create_project!(ws)

    {:ok, _} =
      Tenancy.create_dataset(proj_a2.id, %{slug: "dvp-a2-other-#{tag}", name: "A2 other"})

    {:ok,
     vision: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/_tools/vision",
     workspace: workspace,
     project: proj,
     tag: tag}
  end

  defp signed_in(c, opts \\ []) do
    raw = "dvp-token-" <> Ecto.UUID.generate()
    perms = ["read", "write", "admin"]
    {:ok, _} = Auth.create_token(raw, "dvp", @dataset, perms, c.workspace.id, opts)
    Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})
  end

  defp choices(html, select) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#dk-vision select[#{select}] option")
    |> Enum.map(fn el ->
      frag = LazyHTML.from_fragment(LazyHTML.to_html(el))
      at = fn name -> frag |> LazyHTML.attribute(name) |> List.first() end

      %{
        value: at.("value"),
        label: frag |> LazyHTML.text() |> String.trim(),
        selected: at.("selected") != nil,
        disabled: at.("disabled") != nil
      }
    end)
  end

  test "Dataset lists the page's project's datasets, the page's picked; never another workspace's or project's",
       c do
    {:ok, _view, html} = live(signed_in(c), c.vision)
    picked = choices(html, "data-vision-dataset")
    values = Enum.map(picked, & &1.value)

    expected = c.project.id |> Tenancy.list_datasets() |> Enum.map(& &1.slug)
    assert Enum.sort(values) == Enum.sort(expected)
    assert "dvp-staging-#{c.tag}" in values

    staging = Enum.find(picked, &(&1.value == "dvp-staging-#{c.tag}"))
    assert staging.label == "Staging #{c.tag} (dvp-staging-#{c.tag})"
    refute staging.disabled

    assert [%{value: @dataset}] = Enum.filter(picked, & &1.selected)

    refute html =~ "dvp-b-secret-#{c.tag}", "workspace B's dataset is never on the page"
    refute html =~ "dvp-a2-other-#{c.tag}", "another project's dataset is not this page's"
  end

  # task-bd50893c00e93fe1: an older dataset has documents but no datasets row. The page
  # is that dataset's, so the picker lists it, picked; Fetch reads the picked one
  # (`__desk_vision.test.mjs` §7), never another dataset of the project.
  test "a page dataset with no datasets row is listed and picked, not the project's first", c do
    norow = "dvp-norow-#{c.tag}"
    refute Enum.any?(Tenancy.list_datasets(c.project.id), &(&1.slug == norow))
    vision = String.replace(c.vision, "/d/#{@dataset}/", "/d/#{norow}/")

    {:ok, view, html} = live(signed_in(c), vision)
    picked = choices(html, "data-vision-dataset")

    assert [%{value: ^norow, label: ^norow, disabled: false}] = Enum.filter(picked, & &1.selected)

    assert "dvp-staging-#{c.tag}" in Enum.map(picked, & &1.value),
           "the project's others are still listed"

    assert has_element?(view, ~s{#dk-vision[data-dataset="#{norow}"]})
  end

  test "a dataset-bound token sees the project's other datasets greyed", c do
    {:ok, _view, html} = live(signed_in(c, dataset_bound: true), c.vision)
    picked = choices(html, "data-vision-dataset")

    assert [%{value: @dataset}] = Enum.reject(picked, & &1.disabled)
    assert %{disabled: true} = Enum.find(picked, &(&1.value == "dvp-staging-#{c.tag}"))
  end

  test "API version is Sanity's list, today's last and picked, then Other; its field hidden", c do
    {:ok, view, html} = live(signed_in(c), c.vision)
    versions = choices(html, "data-vision-version")
    today = "v" <> Date.to_iso8601(Date.utc_today())

    assert Enum.map(versions, & &1.value) ==
             ~w(v1 vX v2021-03-25 v2021-10-21 v2022-03-07 v2025-02-19) ++ [today, "other"]

    assert List.last(versions).label == "Other"
    assert [%{value: ^today}] = Enum.filter(versions, & &1.selected)

    assert has_element?(
             view,
             ~s{label:has(select[data-vision-version]) .dk-vision-label},
             "API version"
           )

    assert has_element?(
             view,
             ~s{label:has(select[data-vision-dataset]) .dk-vision-label},
             "Dataset"
           )

    assert has_element?(
             view,
             ~s([data-vision-custom][hidden] input[aria-invalid="true"][value="v"])
           )

    assert has_element?(view, "[data-vision-custom] .dk-vision-label", "Custom API version")
  end
end
