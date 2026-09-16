defmodule Barkpark.Content.SchemaDeskViewsTest do
  @moduledoc """
  Gyldendal parity E10 — `desk.views` is validated at apply time. A view that
  is missing a key would render a tab listing nothing, which an editor reads
  as «there are none»; that is a refusal, not a silent empty tab.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "views-schema-#{System.unique_integer([:positive])}"

  defp apply_views(views) do
    Content.upsert_schema(
      %{
        "name" => "series",
        "title" => "Serie",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}],
        "desk" => %{"views" => views}
      },
      @dataset
    )
  end

  @good %{
    "id" => "boker-i-serien",
    "title" => "Bøker i serien",
    "type" => "publication",
    "by" => "content.series"
  }

  test "a complete view applies, and survives the round trip" do
    assert {:ok, schema} = apply_views([Map.put(@good, "icon", "book")])
    assert [view] = schema.desk["views"]
    assert view["id"] == "boker-i-serien"
    assert view["by"] == "content.series"
  end

  test "orderings are validated like a desk ordering" do
    assert {:ok, _} =
             apply_views([
               Map.put(@good, "orderings", [%{"field" => "title", "direction" => "asc"}])
             ])

    assert {:error, changeset} =
             apply_views([Map.put(@good, "orderings", [%{"direction" => "sideways"}])])

    assert errors_on(changeset)[:desk]
  end

  test "every required key is required" do
    for key <- ~w(id title type by) do
      assert {:error, changeset} = apply_views([Map.delete(@good, key)]),
             "a view missing #{key} was accepted"

      assert errors_on(changeset)[:desk]

      assert {:error, blank} = apply_views([Map.put(@good, key, "   ")]),
             "a view with a blank #{key} was accepted"

      assert errors_on(blank)[:desk]
    end
  end

  test "views must be a list" do
    assert {:error, changeset} = apply_views(%{"id" => "nope"})
    assert errors_on(changeset)[:desk]
  end

  test "a schema with no views keeps an empty desk block" do
    assert {:ok, schema} =
             Content.upsert_schema(
               %{
                 "name" => "plain",
                 "title" => "Plain",
                 "visibility" => "public",
                 "fields" => [%{"name" => "title", "title" => "T", "type" => "string"}]
               },
               @dataset
             )

    assert BarkparkWeb.Studio.StudioLive.Handlers.Views.views_for(schema) == []
  end
end
