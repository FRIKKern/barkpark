defmodule BarkparkWeb.MutateSchemaValidationGapTest do
  @moduledoc """
  task-41a740fd6701ec28 — THE ADVISE-ARM PROOF. This file used to pin the GAP
  (a create violating its schema answered 200 and persisted, unchecked, with no
  signal at all). The mount landed; the file inverted rather than disappearing,
  so the diff shows the contract CHANGING.

  ## What changed, precisely

  `Barkpark.Content.Validation` now runs at the Writer chokepoint
  (`Writer.check_document_schema/3`, called from the create-family funnel and
  the update/upsert funnel) instead of nowhere. The RULING (main, 2026-09-05,
  recorded on the row's `disposition_reason`) is ADVISE-first:

    * **Default, every dataset** — the write still LANDS with the same status
      and the same stored bytes it landed with before, but the finding now
      rides the success envelope as a `warnings` entry (`schema_validation`)
      naming the field and the rule. Silent acceptance became LOUD acceptance.
    * **`enforce_datasets` opt-in, per dataset** — the write is refused 422
      `validation_failed` and the row does not exist afterwards.

  Flipping the default to enforce is the owner's call. The migration story for
  rows already stored in violation lives in `Barkpark.Content.Validation`'s
  moduledoc.

  ## The two mutations this file is armed against

    * Drop `check_document_schema/3` from the Writer chokepoint → the ADVISE
      describes red (no `warnings` key in the envelope).
    * Drop the `Validation.enforce?/1` read → the ENFORCE describes red (the
      write lands 200 instead of 422).

  `async: false` on purpose: the enforce arm sets application env
  (`enforce_datasets`), which is global. The datasets it names are unique per
  run so no concurrent suite can see the flag, but the env WRITE itself must
  not race a sibling test in this file.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  @advise_dataset "test"

  setup do
    token = "barkpark-dev-token-mutate-gap-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", "mutate-schema-validation-gap", ["read", "write", "admin"])

    %{token: token}
  end

  # A flat (v1) schema — no v2 field types, no `validations` slot — so
  # `Validation.validate/3` takes `validate_flat/3` and applies the per-field
  # `"validation"` rule map. `slug` is required AND pattern-constrained.
  defp ruled_type!(dataset) do
    type = "msvgap_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Mutate Gap Type",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "slug",
              "type" => "string",
              "validation" => %{"required" => true, "pattern" => "^[a-z-]+$"}
            }
          ]
        },
        dataset
      )

    type
  end

  # A create lands as a DRAFT (`Writer.do_create_document_from_attrs/4` runs the
  # raw id through `DraftId.draft_id/1`), so the stored row's `doc_id` carries
  # the `drafts.` prefix. Read it back at the id it was actually written to.
  defp read_back(type, dataset, doc_id) do
    Content.get_document(Barkpark.Content.DraftId.draft_id(doc_id), type, dataset)
  end

  defp create(ctx, type, dataset, doc_id, content) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{"create" => Map.merge(%{"_id" => doc_id, "_type" => type}, content)}
        ]
      })
    )
  end

  defp schema_warnings(body) do
    body
    |> Map.get("warnings", [])
    |> Enum.filter(&(&1["code"] == "schema_validation"))
  end

  describe "ADVISE (the default) — the write lands, and it now says what it broke" do
    test "a create MISSING a required field still answers 200 — and warns, naming field + rule",
         ctx do
      type = ruled_type!(@advise_dataset)
      doc_id = "msvgap-missing-#{System.unique_integer([:positive])}"

      refute Validation.enforce?(@advise_dataset),
             "this arm proves the DEFAULT; a dataset opted into enforcement would 422 here"

      resp = create(ctx, type, @advise_dataset, doc_id, %{"content" => %{"title" => "No slug"}})

      # NOT a refusal. The ruling is explicit: advisories never block, so the
      # status and the stored row are what they were before the mount.
      assert resp.status == 200
      body = json_response(resp, 200)
      assert is_binary(body["transactionId"])

      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)
      refute Map.has_key?(doc.content || %{}, "slug")

      # THE MOUNT ASSERTION. Drop `check_document_schema/3` from the Writer
      # chokepoint and this is what reds: the acceptance goes silent again.
      assert [warning] = schema_warnings(body)
      assert warning["severity"] == "warning"

      assert warning["message"] =~ "slug",
             "the advisory must name the offending FIELD, got #{inspect(warning["message"])}"

      assert String.downcase(warning["message"]) =~ "required",
             "the advisory must name the RULE it broke, got #{inspect(warning["message"])}"

      assert warning["message"] =~ type, "the advisory names the type it is about"
      assert warning["message"] =~ doc_id, "the advisory names the document it is about"
    end

    test "a create VIOLATING a field pattern answers 200, stores the bad value, and warns",
         ctx do
      type = ruled_type!(@advise_dataset)
      doc_id = "msvgap-pattern-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Bad slug", "slug" => "NOT A SLUG 42"}
        })

      assert resp.status == 200
      body = json_response(resp, 200)

      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)

      assert doc.content["slug"] == "NOT A SLUG 42",
             "advise never rewrites content — the violating value is stored verbatim"

      assert [warning] = schema_warnings(body)
      assert warning["message"] =~ "slug"
    end
  end

  describe "ENFORCE (per-dataset opt-in) — refused 422, and the row is NOT there afterwards" do
    setup do
      dataset = "msvenf_#{System.unique_integer([:positive])}"
      previous = Application.get_env(:barkpark, Validation, [])

      Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
      on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

      %{enforce_dataset: dataset, type: ruled_type!(dataset)}
    end

    test "the flag is what selects the arm — only the opted-in dataset enforces", ctx do
      assert Validation.enforce?(ctx.enforce_dataset)
      refute Validation.enforce?(@advise_dataset)
    end

    test "a create violating `required` is refused 422 AND the document does not exist", ctx do
      doc_id = "msvenf-missing-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, ctx.type, ctx.enforce_dataset, doc_id, %{"content" => %{"title" => "No slug"}})

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"

      assert get_in(body, ["error", "details", "slug"]),
             "details must name the offending field, got #{inspect(body["error"]["details"])}"

      # THE ROW ASSERTION, and the reason this test is not status-only: a
      # status-only assertion stays green against an implementation that 422s
      # and writes anyway.
      refute match?({:ok, _}, read_back(ctx.type, ctx.enforce_dataset, doc_id)),
             "the refused document must not exist — a 422 that still persisted is the worst arm"
    end

    test "a create SATISFYING the schema still lands 200 under enforcement", ctx do
      doc_id = "msvenf-good-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, ctx.type, ctx.enforce_dataset, doc_id, %{
          "content" => %{"title" => "Good", "slug" => "good-slug"}
        })

      assert resp.status == 200
      assert {:ok, doc} = read_back(ctx.type, ctx.enforce_dataset, doc_id)
      assert doc.content["slug"] == "good-slug"
    end
  end

  describe "THE VALIDATOR ITSELF — unchanged by the mount, still the same verdicts" do
    test "Content.validate_document/4 REFUSES content missing a required field" do
      type = ruled_type!(@advise_dataset)

      assert {:error, errors} =
               Content.validate_document(
                 type,
                 "No slug at all",
                 %{"title" => "x"},
                 @advise_dataset
               )

      assert Map.has_key?(errors, "slug"),
             "expected the required-field refusal to name `slug`, got #{inspect(errors)}"
    end

    test "…and it accepts content that satisfies the schema, so the refusal is not blanket" do
      type = ruled_type!(@advise_dataset)

      assert {:ok, _} =
               Content.validate_document(
                 type,
                 "Good",
                 %{"title" => "Good", "slug" => "good-slug"},
                 @advise_dataset
               )
    end
  end

  describe "NEGATIVE ARM — byte-unchanged where no declared rule is broken" do
    test "a create with no _type is still refused 422, not silently accepted", ctx do
      resp =
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/data/mutate/#{@advise_dataset}",
          Jason.encode!(%{
            "mutations" => [%{"create" => %{"_id" => "msvgap-no-type", "title" => "x"}}]
          })
        )

      assert resp.status == 422
    end

    test "content that SATISFIES its schema: same status, same bytes, no advisory", ctx do
      type = ruled_type!(@advise_dataset)
      doc_id = "msvgap-good-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Good", "slug" => "good-slug"}
        })

      assert resp.status == 200
      assert schema_warnings(json_response(resp, 200)) == []

      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)
      assert doc.content["title"] == "Good"
      assert doc.content["slug"] == "good-slug"
    end

    test "a type with NO SCHEMA AT ALL: same status, same bytes, no advisory", ctx do
      type = "msvgap_noschema_#{System.unique_integer([:positive])}"
      doc_id = "msvgap-noschema-#{System.unique_integer([:positive])}"

      assert {:error, _} = Content.get_schema(type, @advise_dataset)

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"anything" => "at all", "slug" => "NOT A SLUG 42"}
        })

      assert resp.status == 200
      assert schema_warnings(json_response(resp, 200)) == []

      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)
      assert doc.content["anything"] == "at all"
      assert doc.content["slug"] == "NOT A SLUG 42"
    end

    test "a schema with NO VALIDATION RULES: same status, same bytes, no advisory", ctx do
      type = "msvgap_norules_#{System.unique_integer([:positive])}"
      doc_id = "msvgap-norules-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "No Rules Type",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "slug", "type" => "string"}
            ]
          },
          @advise_dataset
        )

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Whatever", "slug" => "NOT A SLUG 42"}
        })

      assert resp.status == 200
      assert schema_warnings(json_response(resp, 200)) == []

      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)
      assert doc.content["slug"] == "NOT A SLUG 42"
    end
  end
end
