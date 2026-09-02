defmodule BarkparkWeb.MutateSchemaValidationGapTest do
  @moduledoc """
  task-19b7ca7ff92fb710 (#3), DEFERRED HALF — pinned here as CURRENT BEHAVIOUR,
  deliberately, with the row that will invert it named in every assertion that
  encodes the gap.

  ## Read this before you "fix" a failing assertion in this file

  The assertions tagged `@tag :known_gap` below assert the WRONG contract on
  purpose. They say: today, a document create whose content violates its own
  schema's `required` rule answers 200 and PERSISTS. That is not the contract
  anyone wants; it is the contract that exists. When the enforcement lands
  (**task-41a740fd6701ec28**), these tests red — and that red is the signal to
  INVERT them, not to delete them.

  ## What is and is not fixed

  The REPORTED mechanism of S2 #3 — top-level keys silently dropped from a
  create, which cost Gyldendal `acceptance_criteria` on seven tasks — IS fixed
  on main and is covered elsewhere: `Writer.refuse_orphan_top_level_keys/1`
  answers 422 `unknown_fields` naming every offending key, and the flat branch
  of `from_envelope/1` folds top-level keys into `content` rather than
  discarding them.

  What is NOT fixed is the sibling: content INSIDE the envelope is never
  schema-validated on the mutate path. `Barkpark.Content.Validation.validate/3`
  is complete and correct — the third test below calls it directly and watches
  it refuse the exact payload the HTTP door accepted — but its wrapper
  `Content.validate_document/4` has only two call sites in the whole tree
  (`content/forms.ex` and the Studio LiveView doc handler), and neither is a
  write door. So this is silent ACCEPTANCE where #3 reported silent DROPPING:
  the same defect class, the opposite mechanism.

  ## Why it was deferred rather than built (the reason, recorded, not omitted)

  Wiring the validator into `Writer.create_document/4` flips every already-loose
  document on every instance from 200 to 422 on its next write. That is a
  product ruling with a migration attached, not a P0 patch, and shipping it
  inside a silent-failure fix would have been an unannounced breaking change.
  The ruling, the blast-radius measurement, the enforcement and the migration
  story are the six criteria of **task-41a740fd6701ec28**.

  The third test is the load-bearing one. Without it "the door does not
  validate" is indistinguishable from "there is nothing to validate with", and
  the follow-on row would be asking someone to build a validator that already
  exists.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content

  @dataset "test"

  setup do
    token = "barkpark-dev-token-mutate-gap-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", "mutate-schema-validation-gap", ["read", "write", "admin"])

    type = "msvgap_#{System.unique_integer([:positive])}"

    # A flat (v1) schema — no v2 field types, no `validations` slot — so
    # `Validation.validate/3` takes `validate_flat/3` and applies the per-field
    # `"validation"` rule map. `slug` is required AND pattern-constrained.
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
        @dataset
      )

    %{token: token, type: type}
  end

  # A create lands as a DRAFT (`Writer.do_create_document_from_attrs/4` runs the
  # raw id through `DraftId.draft_id/1`), so the stored row's `doc_id` carries
  # the `drafts.` prefix. Read it back at the id it was actually written to.
  defp read_back!(ctx, doc_id) do
    Content.get_document(Barkpark.Content.DraftId.draft_id(doc_id), ctx.type, @dataset)
  end

  defp create!(ctx, doc_id, content) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{"create" => Map.merge(%{"_id" => doc_id, "_type" => ctx.type}, content)}
        ]
      })
    )
  end

  describe "CURRENT BEHAVIOUR (the gap) — content is never validated against its schema" do
    @tag :known_gap
    test "a create MISSING a required field answers 200 and persists — task-41a740fd6701ec28",
         ctx do
      doc_id = "msvgap-missing-#{System.unique_integer([:positive])}"

      resp = create!(ctx, doc_id, %{"content" => %{"title" => "No slug at all"}})

      # THE GAP. When task-41a740fd6701ec28 lands this becomes 422 and the two
      # assertions below invert. Do not delete them to make the suite green.
      assert resp.status == 200,
             "the mutate door started validating content — invert this test, see " <>
               "task-41a740fd6701ec28"

      body = json_response(resp, 200)
      assert is_binary(body["transactionId"])

      # The ROW assertion, which is the one that matters: a status-only test
      # would not distinguish "refused" from "refused and written anyway".
      assert {:ok, doc} = read_back!(ctx, doc_id)
      refute Map.has_key?(doc.content || %{}, "slug")
    end

    @tag :known_gap
    test "a create VIOLATING a field pattern answers 200 and persists the bad value",
         ctx do
      doc_id = "msvgap-pattern-#{System.unique_integer([:positive])}"

      resp =
        create!(ctx, doc_id, %{"content" => %{"title" => "Bad slug", "slug" => "NOT A SLUG 42"}})

      assert resp.status == 200,
             "the mutate door started validating content — invert this test, see " <>
               "task-41a740fd6701ec28"

      assert {:ok, doc} = read_back!(ctx, doc_id)

      assert doc.content["slug"] == "NOT A SLUG 42",
             "the value that violates ^[a-z-]+$ is stored verbatim"
    end
  end

  describe "THE VALIDATOR ITSELF IS NOT THE PROBLEM — it works, it is simply never called" do
    test "Content.validate_document/4 REFUSES the exact payload the HTTP door accepted", ctx do
      # Same type, same dataset, same content as the first gap test. If this
      # ever stops refusing, the follow-on row's premise is wrong and it should
      # be re-scoped rather than built.
      assert {:error, errors} =
               Content.validate_document(ctx.type, "No slug at all", %{"title" => "x"}, @dataset)

      assert Map.has_key?(errors, "slug"),
             "expected the required-field refusal to name `slug`, got #{inspect(errors)}"
    end

    test "…and it accepts content that satisfies the schema, so the refusal is not blanket",
         ctx do
      assert {:ok, _} =
               Content.validate_document(
                 ctx.type,
                 "Good",
                 %{"title" => "Good", "slug" => "good-slug"},
                 @dataset
               )
    end
  end

  describe "NEGATIVE ARM — the create door's EXISTING refusals are untouched" do
    test "a create with no _type is still refused 422, not silently accepted", ctx do
      resp =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{
            "mutations" => [%{"create" => %{"_id" => "msvgap-no-type", "title" => "x"}}]
          })
        )

      assert resp.status == 422
    end

    test "a create whose content SATISFIES the schema is accepted and stored intact", ctx do
      doc_id = "msvgap-good-#{System.unique_integer([:positive])}"

      resp =
        create!(ctx, doc_id, %{"content" => %{"title" => "Good", "slug" => "good-slug"}})

      assert resp.status == 200
      assert {:ok, doc} = read_back!(ctx, doc_id)
      assert doc.content["slug"] == "good-slug"
    end
  end
end
