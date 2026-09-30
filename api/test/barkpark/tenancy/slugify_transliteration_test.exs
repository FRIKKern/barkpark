defmodule Barkpark.Tenancy.SlugifyTransliterationTest do
  @moduledoc """
  task-f5a0b3e391c5fb29 — workspace and project slugs TRANSLITERATE accented and
  ligature Latin letters instead of dropping them ("Nytt prosjekt Æøå" derived
  `nytt-prosjekt`, "Blåbær" `bl-b-r`), with the same rule as Studio's document
  slug Generate (#20729). ASCII derives byte-identically; stored slugs never move.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Project

  describe "slugify/1" do
    test "transliterates Norwegian and other Latin letters" do
      assert Tenancy.slugify("Nytt prosjekt Æøå") == "nytt-prosjekt-aeoa"
      assert Tenancy.slugify("Blåbær") == "blabaer"
      assert Tenancy.slugify("Ærlig Øl") == "aerlig-ol"
      assert Tenancy.slugify("Crème Brûlée für Łódź — Straße") == "creme-brulee-fur-lodz-strasse"
    end

    test "ASCII input derives byte-identically to the old rule" do
      old = fn name ->
        name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
      end

      for name <- ["Default", "My Workspace 2", "  a--b__c  ", "!!!", "", "Gyldendal Norsk"] do
        assert Tenancy.slugify(name) == old.(name), "ASCII #{inspect(name)} changed"
      end
    end

    test "agrees with Studio's document-slug Generate on every sample" do
      for name <- ["Blåbær & Søt! Æøå", "Kjære Åse Øvrebø", "Crème Brûlée für Łódź — Straße"] do
        assert Tenancy.slugify(name) ==
                 BarkparkWeb.Studio.StudioLive.Handlers.Fields.document_slug(name)
      end
    end
  end

  describe "derived slugs on create" do
    test "a workspace and a project named with Æøå derive transliterated slugs" do
      user =
        Barkpark.AccountsFixtures.register_user(
          "slug-#{System.unique_integer([:positive])}@example.com"
        )

      {:ok, ws} =
        Tenancy.create_workspace_with_owner(
          %{name: "Blåbær #{System.unique_integer([:positive])}"},
          user
        )

      assert ws.slug =~ ~r/^blabaer-\d+$/

      {:ok, project} = Tenancy.create_project_with_dataset(ws, %{name: "Nytt prosjekt Æøå"})
      assert project.slug == "nytt-prosjekt-aeoa"
    end

    test "a stored slug is never rewritten, and an explicit slug still wins" do
      ws = create_workspace!()
      {:ok, legacy} = Tenancy.create_project(ws, %{name: "Blåbær", slug: "bl-b-r"})

      assert legacy.slug == "bl-b-r"
      assert Repo.get!(Project, legacy.id).slug == "bl-b-r"
    end
  end
end
