defmodule Barkpark.Search.SurfaceConfigHighlightFieldsTest do
  @moduledoc """
  task-5cf80a99ecd52bf2: `update-search-settings` accepted a `highlightFields`
  entry that matched none of `Barkpark.Search.Highlighter`'s hardcoded field
  clauses. The write succeeded (200), and the row sat corrupted until the
  NEXT `GET /v1/media/:dataset/search` (or documents-surface search) crashed
  with a `FunctionClauseError` in `media_field_text/3` — a stored-config
  denial of service that persists until someone manually reverts the row.

  This is the WRITE-side half of the fix (the primary one — it stops the row
  ever being corrupted): `SurfaceConfig.changeset/2` now validates
  `highlight_fields` entries against each surface's actual highlightable
  field set, mirroring the `zero_hit_strategy` / `typo_policy` refusal
  pattern already proven out in `surface_config_refuses_dead_knobs_test.exs`.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Search.SurfaceConfigs

  @scope "production"

  setup do
    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    SurfaceConfigs.seed_defaults!()
    SurfaceConfigs.__reset_cache_for_test__()
    {:ok, ws: create_workspace!()}
  end

  defp errors(changeset), do: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)

  describe "media surface: highlightFields must be a field media_field_text/3 handles" do
    test "an unrecognized field name is refused and named, not stored", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "media",
                 @scope,
                 %{"highlightFields" => ["cliverbs-media-marker"]},
                 ws.id
               )

      assert %{highlight_fields: [message]} = errors(changeset)
      assert message =~ "cliverbs-media-marker"

      # And the refusal did not write: the caller's config is still the default.
      assert SurfaceConfigs.get("media", @scope, ws.id)["highlight_fields"] ==
               ["title", "original_name", "filename"]
    end

    for field <- ~w(title original_name filename tags) do
      test "#{field} (a real media_field_text/3 clause) is accepted", %{ws: ws} do
        field = unquote(field)

        assert {:ok, echo} =
                 SurfaceConfigs.upsert("media", @scope, %{"highlightFields" => [field]}, ws.id)

        assert echo["highlight_fields"] == [field]
      end
    end

    test "a mix of good and bad values names only the bad one", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "media",
                 @scope,
                 %{"highlightFields" => ["title", "not-a-real-field"]},
                 ws.id
               )

      assert %{highlight_fields: [message]} = errors(changeset)
      assert message =~ "not-a-real-field"
      refute message =~ "\"title\""
    end
  end

  describe "documents surface: highlightFields accepts title + any content.* path" do
    test "title is accepted", %{ws: ws} do
      assert {:ok, echo} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"highlightFields" => ["title"]},
                 ws.id
               )

      assert echo["highlight_fields"] == ["title"]
    end

    test "an arbitrary content.* path is accepted (open-ended by design)", %{ws: ws} do
      assert {:ok, echo} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"highlightFields" => ["content.anything-the-schema-declares"]},
                 ws.id
               )

      assert echo["highlight_fields"] == ["content.anything-the-schema-declares"]
    end

    test "a field name that is neither title nor content.* is refused", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"highlightFields" => ["cliverbs-doc-marker"]},
                 ws.id
               )

      assert %{highlight_fields: [message]} = errors(changeset)
      assert message =~ "cliverbs-doc-marker"
    end
  end
end
