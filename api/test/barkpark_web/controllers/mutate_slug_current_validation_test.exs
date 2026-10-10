defmodule BarkparkWeb.MutateSlugCurrentValidationTest do
  @moduledoc """
  task-bb7c45fe5e501d76 — a slug field's `pattern`/`min`/`max`/`required`
  rules are all `is_binary(value)`-guarded leaf checks. Written as the bare
  string shape (`"slug": "Bad Slug"`) they fire correctly; written as
  Sanity's slug object shape (`"slug": {"_type": "slug", "current": "Bad
  Slug"}` — the shape Studio's own slug input stores, per owner ruling #43 /
  task-26394ff887df3261) the rule silently never ran at all, a real bypass
  on an enforcing dataset. Found live on barkpark-studio's
  studio-parity/e2e-freeform advisory dataset.

  `Validation.validate_field/3` now unwraps `.current` before running any
  rule check, gated on the FIELD's own declared type (`"slug"`) rather than
  the value's self-reported `_type` — so an unrelated field is never
  reinterpreted.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  @ds "production"

  setup do
    token = "barkpark-dev-token-slugval-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      "slug-current-validation",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    %{token: token}
  end

  defp schema!(dataset) do
    type = "slugval_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "SlugVal",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "slug",
              "type" => "slug",
              "validation" => %{
                "required" => true,
                "pattern" => "^[a-z0-9]+(?:-[a-z0-9]+)*$",
                "message" => "slug must be lowercase, numbers and hyphens only"
              }
            }
          ]
        },
        dataset
      )

    type
  end

  defp mutate(ctx, dataset, type, doc_id, slug) do
    mutation = %{
      "mutations" => [
        %{
          "create" => %{
            "_type" => type,
            "doc_id" => doc_id,
            "title" => "T",
            "content" => %{"slug" => slug}
          }
        }
      ]
    }

    ctx.conn
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{dataset}", Jason.encode!(mutation))
  end

  describe "ADVISE (default dataset)" do
    test "the bare-string shape warns (control -- this already worked)", ctx do
      type = schema!(@ds)
      doc_id = "slugval-str-#{System.unique_integer([:positive])}"

      resp = mutate(ctx, @ds, type, doc_id, "Bad Slug")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      [warning] = body["warnings"]
      assert [%{"code" => "custom"}] = warning["findings"]
    end

    test "the {current} object shape warns IDENTICALLY (THE GAP)", ctx do
      type = schema!(@ds)
      doc_id = "slugval-obj-#{System.unique_integer([:positive])}"

      resp = mutate(ctx, @ds, type, doc_id, %{"_type" => "slug", "current" => "Bad Slug"})
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      [warning] = body["warnings"]
      assert [%{"code" => "custom"}] = warning["findings"]
    end

    test "a {current} with no current value at all warns as required", ctx do
      type = schema!(@ds)
      doc_id = "slugval-blank-#{System.unique_integer([:positive])}"

      resp = mutate(ctx, @ds, type, doc_id, %{"_type" => "slug"})
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      [warning] = body["warnings"]
      assert [%{"code" => "custom"}] = warning["findings"]
    end

    test "a VALID {current} slug gets no advisory", ctx do
      type = schema!(@ds)
      doc_id = "slugval-ok-#{System.unique_integer([:positive])}"

      resp = mutate(ctx, @ds, type, doc_id, %{"_type" => "slug", "current" => "good-slug"})
      assert resp.status == 200
      refute Map.has_key?(Jason.decode!(resp.resp_body), "warnings")
    end
  end

  describe "ENFORCE (per-dataset opt-in)" do
    setup do
      dataset = "slugval_enf_#{System.unique_integer([:positive])}"
      previous = Application.get_env(:barkpark, Validation, [])
      Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
      on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)
      %{dataset: dataset}
    end

    test "the {current} object shape is refused 422, same as the bare string (THE GAP, enforced)",
         %{dataset: dataset} = ctx do
      type = schema!(dataset)
      doc_id = "slugval-enf-obj-#{System.unique_integer([:positive])}"

      resp = mutate(ctx, dataset, type, doc_id, %{"_type" => "slug", "current" => "Bad Slug"})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"

      refute match?(
               {:ok, _},
               Content.get_document("drafts." <> doc_id, type, dataset)
             )
    end

    test "a VALID {current} slug still lands 200 under enforcement", %{dataset: dataset} = ctx do
      type = schema!(dataset)
      doc_id = "slugval-enf-ok-#{System.unique_integer([:positive])}"

      resp = mutate(ctx, dataset, type, doc_id, %{"_type" => "slug", "current" => "good-slug"})
      assert resp.status == 200
    end
  end

  describe "the validator directly -- an unrelated field is never reinterpreted" do
    test "a STRING field (not type slug) with a current-shaped map is left alone" do
      schema = %{
        "fields" => [
          %{
            "name" => "note",
            "type" => "string",
            "validation" => %{"pattern" => "^[a-z]+$"}
          }
        ]
      }

      result =
        Validation.check_findings(%{"note" => %{"current" => "Not Lowercase"}}, "T", schema)

      # pattern_mismatch never fires: check_pattern/2 is is_binary-guarded,
      # and this field is NOT declared type "slug" so unwrap_slug/2 leaves
      # the map untouched -- same (lack of) coverage as before this fix,
      # proving the fix is scoped to slug-typed fields only.
      refute Enum.any?(result.errors, &(&1.code == :pattern_mismatch))
    end
  end
end
