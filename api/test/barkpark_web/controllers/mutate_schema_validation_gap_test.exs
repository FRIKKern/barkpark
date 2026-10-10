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

    Auth.create_token(
      token,
      "dev",
      "mutate-schema-validation-gap",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

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

    test "two distinct rule violations get two warnings, each carrying its own code+params (task-3f46241a2a9c3656)",
         ctx do
      type = "msvgap_codes_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Mutate Gap Codes Type",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{
                "name" => "slug",
                "type" => "string",
                "validation" => %{"required" => true}
              },
              %{
                "name" => "handle",
                "type" => "string",
                "validation" => %{"pattern" => "^[a-z-]+$"}
              }
            ]
          },
          @advise_dataset
        )

      doc_id = "msvgap-codes-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Two breaks", "handle" => "NOT A SLUG 42"}
        })

      assert resp.status == 200
      body = json_response(resp, 200)

      warnings = schema_warnings(body)

      assert length(warnings) == 2,
             "expected one advisory per offending field, got #{inspect(warnings)}"

      by_field = Map.new(warnings, fn w -> {Enum.at(w["findings"], 0)["path"], w} end)

      slug_warning = Map.fetch!(by_field, "/slug")
      assert [%{"code" => "required", "path" => "/slug"}] = slug_warning["findings"]

      handle_warning = Map.fetch!(by_field, "/handle")
      assert [%{"code" => "pattern_mismatch", "path" => "/handle"}] = handle_warning["findings"]

      # ADDITIVE: the message-joining the mount has always done is unchanged.
      assert slug_warning["message"] =~ "slug"
      assert handle_warning["message"] =~ "handle"
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

    test "a create violating TWO distinct rules carries both finding codes on the wire (task-1dac662bed153203)",
         ctx do
      type = "msvenf_codes_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Findings Codes Type",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "slug", "type" => "string", "validation" => %{"required" => true}},
              %{
                "name" => "handle",
                "type" => "string",
                "validation" => %{"pattern" => "^[a-z-]+$"}
              }
            ]
          },
          ctx.enforce_dataset
        )

      doc_id = "msvenf-codes-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, ctx.enforce_dataset, doc_id, %{
          "content" => %{"title" => "Two breaks", "handle" => "NOT A SLUG 42"}
        })

      assert resp.status == 422
      body = json_response(resp, 422)

      # THE ADDITIVE ASSERTION: `details` carries exactly what it always has —
      # drop `findings` entirely and this half of the test still passes.
      assert get_in(body, ["error", "details", "slug"]), "details must still name `slug`"
      assert get_in(body, ["error", "details", "handle"]), "details must still name `handle`"

      findings = get_in(body, ["error", "findings"]) || []
      codes = Enum.map(findings, & &1["code"])

      assert "required" in codes,
             "expected a `required` finding for the missing slug, got #{inspect(codes)}"

      assert "pattern_mismatch" in codes,
             "expected a `pattern_mismatch` finding for the bad handle, got #{inspect(codes)}"

      # Each finding's `message` is byte-identical to its entry under
      # `details` — the structured list is a parallel view, not a rewrite.
      for finding <- findings do
        path = String.trim_leading(finding["path"], "/")

        assert (get_in(body, ["error", "details", path]) || [])
               |> Enum.member?(finding["message"]),
               "finding #{inspect(finding)} message must appear under details[#{inspect(path)}]"
      end
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

    # task-3c085ff3fc199ba7 — the ENFORCE half of the unknown_type advisory
    # above: a type with no schema at all, in a dataset opted into
    # enforcement, is refused rather than advised, same as any other schema
    # violation on that dataset.
    test "a type with NO SCHEMA AT ALL is refused 422 AND the document does not exist",
         ctx do
      type = "msvenf_noschema_#{System.unique_integer([:positive])}"
      doc_id = "msvenf-noschema-#{System.unique_integer([:positive])}"

      assert {:error, _} = Content.get_schema(type, ctx.enforce_dataset)

      resp =
        create(ctx, type, ctx.enforce_dataset, doc_id, %{"content" => %{"anything" => "here"}})

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"
      assert get_in(body, ["error", "details", "_type"])

      findings = get_in(body, ["error", "findings"]) || []
      assert [%{"code" => "unknown_type", "path" => "/_type"}] = findings

      refute match?({:ok, _}, read_back(type, ctx.enforce_dataset, doc_id)),
             "the refused document must not exist"
    end

    # task-3c085ff3fc199ba7 safety pass: a system-internal type must not
    # newly get the unknown_type advisory/refusal. Proven on the dataset
    # that's opted into enforcement, the strictest arm.
    test "a system-internal type with no schema still lands 200 under enforcement (tag, HTTP)",
         ctx do
      doc_id = "msvenf-sys-tag-#{System.unique_integer([:positive])}"
      resp = create(ctx, "tag", ctx.enforce_dataset, doc_id, %{"content" => %{"title" => "x"}})

      assert resp.status == 200
      refute Map.has_key?(json_response(resp, 200), "warnings")
      assert {:ok, _doc} = read_back("tag", ctx.enforce_dataset, doc_id)
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

    # task-3c085ff3fc199ba7 CHANGED THIS CONTRACT ON PURPOSE: a type with no
    # declared schema used to write silently forever (sanity.imageAsset,
    # sanity.previewUrlSecret, any Sanity-internal or just-not-yet-modeled
    # type) — the exact gap this test used to pin as "byte-unchanged". It now
    # gets the SAME unknown_type advisory every other schema violation
    # already has (same code `Validation`'s richText block-member check
    # already uses for an unknown block `_type`); the write still LANDS
    # (same status, same stored bytes — ADVISE never blocks) and still has
    # no SCHEMA rule to violate, so this is the one remaining assertion this
    # describe block's name is about.
    test "a type with NO SCHEMA AT ALL: same status, same bytes, now ADVISES unknown_type", ctx do
      type = "msvgap_noschema_#{System.unique_integer([:positive])}"
      doc_id = "msvgap-noschema-#{System.unique_integer([:positive])}"

      assert {:error, _} = Content.get_schema(type, @advise_dataset)

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"anything" => "at all", "slug" => "NOT A SLUG 42"}
        })

      assert resp.status == 200

      assert [warning] = schema_warnings(json_response(resp, 200))
      assert warning["severity"] == "warning"
      assert warning["message"] =~ type
      assert [%{"code" => "unknown_type", "path" => "/_type"}] = warning["findings"]

      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)
      assert doc.content["anything"] == "at all"
      assert doc.content["slug"] == "NOT A SLUG 42"
    end

    # task-3c085ff3fc199ba7 safety pass — the ADVISE-mode twin of the
    # ENFORCE-mode system-type test above: no advisory noise on an
    # ordinary write of one of Barkpark's own bookkeeping types either.
    test "a system-internal type with no schema gets no unknown_type advisory (tag, HTTP)",
         ctx do
      doc_id = "msvgap-sys-tag-#{System.unique_integer([:positive])}"
      resp = create(ctx, "tag", @advise_dataset, doc_id, %{"content" => %{"title" => "x"}})

      assert resp.status == 200
      assert schema_warnings(json_response(resp, 200)) == []
    end

    # task-3c085ff3fc199ba7 safety pass — the REST of @system_types
    # (task/listener/form_submission/form_endpoint) each carry their OWN
    # structural validation UNRELATED to Content.Validation (Barkpark.Tasks'
    # required kind/lifecycle_status; the Forms plugin's Contract.validate/2
    # hook), which would 422 a generic test payload for reasons that have
    # nothing to do with unknown_type — so proven directly against the unit
    # under test (Writer.check_document_schema/3) instead of through the
    # full HTTP door and every OTHER hook that door also runs. The
    # exemption clause short-circuits on `type` alone, before any content
    # is even read, so an arbitrary/empty attrs map is a valid probe for
    # every member of the list.
    test "every @system_types entry short-circuits to :ok regardless of content, in BOTH modes" do
      for type <- ~w(tag task listener form_submission form_endpoint ticket) do
        assert Content.Writer.check_document_schema(type, %{}, @advise_dataset) == :ok,
               "#{type}: expected :ok under ADVISE"

        enforce_dataset = "msvsys_enf_#{type}_#{System.unique_integer([:positive])}"
        previous = Application.get_env(:barkpark, Validation, [])
        Application.put_env(:barkpark, Validation, enforce_datasets: [enforce_dataset])

        assert Content.Writer.check_document_schema(type, %{}, enforce_dataset) == :ok,
               "#{type}: expected :ok under ENFORCE"

        Application.put_env(:barkpark, Validation, previous)
      end
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

  describe "WARNING-LEVEL-ONLY rules (task-292d6677b94916ef)" do
    # Bug report from barkpark-studio, found while using #22406: a warning-level
    # rule with NO co-occurring error-level violation produced zero `warnings`
    # at all. `validate_document_findings/5` only ever consulted
    # `Validation.validate/3` (ERROR-level only) to decide `:ok` vs `:error`,
    # and on `:ok` returned immediately without reading `check_findings/3`'s
    # `warnings` half — so `do_check_document_schema/4`'s `{:ok, _content} ->
    # :ok` branch never called an advisory emitter for them. Proven first for
    # an array `max`, then `min`, then a non-array rule (string `max` length)
    # to show the fix is general, not array-specific.
    defp array_max_type!(dataset) do
      type = "msvgap_arrmax_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Array Max Warning Type",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{
                "name" => "tags",
                "type" => "arrayOf",
                "of" => %{"type" => "string"},
                "validation" => %{"max" => 3, "level" => "warning"}
              }
            ]
          },
          dataset
        )

      type
    end

    defp array_min_type!(dataset) do
      type = "msvgap_arrmin_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Array Min Warning Type",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{
                "name" => "tags",
                "type" => "arrayOf",
                "of" => %{"type" => "string"},
                "validation" => %{"min" => 2, "level" => "warning"}
              }
            ]
          },
          dataset
        )

      type
    end

    defp string_max_warning_type!(dataset) do
      type = "msvgap_strmax_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "String Max Warning Type",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{
                "name" => "summary",
                "type" => "string",
                "validation" => %{"max" => 5, "level" => "warning"}
              }
            ]
          },
          dataset
        )

      type
    end

    test "an array `max` rule at warning level, violated ALONE, still warns", ctx do
      type = array_max_type!(@advise_dataset)
      doc_id = "msvgap-arrmax-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Too many", "tags" => ["a", "b", "c", "d"]}
        })

      # The write still lands — a warning-level rule never blocks (same as the
      # ADVISE arm above).
      assert resp.status == 200
      body = json_response(resp, 200)
      assert {:ok, doc} = read_back(type, @advise_dataset, doc_id)
      assert doc.content["tags"] == ["a", "b", "c", "d"]

      # THE GAP: before the fix this is `[]`. An array-length violation at
      # level warning, with no error-level violation anywhere else in the
      # document, must still produce an advisory naming the field and rule.
      assert [warning] = schema_warnings(body)
      assert warning["severity"] == "warning"
      assert warning["message"] =~ "tags"

      assert [%{"code" => code, "path" => "/tags"}] = warning["findings"]
      assert to_string(code) =~ "list_too_long"
    end

    test "an array `min` rule at warning level, violated ALONE, still warns", ctx do
      type = array_min_type!(@advise_dataset)
      doc_id = "msvgap-arrmin-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Too few", "tags" => ["a"]}
        })

      assert resp.status == 200
      body = json_response(resp, 200)

      assert [warning] = schema_warnings(body)
      assert warning["message"] =~ "tags"
      assert [%{"code" => code, "path" => "/tags"}] = warning["findings"]
      assert to_string(code) =~ "list_too_short"
    end

    test "a NON-ARRAY warning rule (string max length), violated alone, still warns — proves the fix is general",
         ctx do
      type = string_max_warning_type!(@advise_dataset)
      doc_id = "msvgap-strmax-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "x", "summary" => "way too long for five chars"}
        })

      assert resp.status == 200
      body = json_response(resp, 200)

      assert [warning] = schema_warnings(body)
      assert warning["message"] =~ "summary"
      assert [%{"path" => "/summary"}] = warning["findings"]
    end

    test "content satisfying the warning-level rule: same status, no advisory", ctx do
      type = array_max_type!(@advise_dataset)
      doc_id = "msvgap-arrok-#{System.unique_integer([:positive])}"

      resp =
        create(ctx, type, @advise_dataset, doc_id, %{
          "content" => %{"title" => "Fine", "tags" => ["a", "b"]}
        })

      assert resp.status == 200
      assert schema_warnings(json_response(resp, 200)) == []
    end
  end
end
