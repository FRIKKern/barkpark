defmodule BarkparkWeb.SchemaValidateOnlyTest do
  @moduledoc """
  task-19b7ca7ff92fb710 (#21) — `POST /v1/schemas/:dataset` with
  `validate_only: true`.

  THE GAP THIS CLOSES. `bp schema apply --dry-run` never reached the server:
  `--dry-run` is a GLOBAL bp flag and `internal/cli/run.go` prints the resolved
  request and returns BEFORE the send, for every manifest command. So the only
  way to learn whether the server would accept a schema was to write it — and
  a rejected write is discovered as a 422 you have already committed to, while
  an ACCEPTED-but-wrong one is discovered by whatever breaks next.

  WHAT THE TESTS BELOW ARE SHAPED TO CATCH. The response body is the weak
  assertion here: an implementation that validates AND WRITES answers exactly
  the same 200 as the correct one. So every validate-only test reads the STORE
  back — `Content.get_schema/2` plus the public `GET /v1/schemas/:dataset/:name`
  — and asserts absence (new schema) or byte-equality (existing schema). That
  read-back is the test; the status code is the decoration.

  MUTATION PROOF (pasted into the row's evidence): pointing the `validate_only?`
  branch at `Content.upsert_schema/3` instead of `Content.Schema.validate_schema/3`
  leaves every status assertion GREEN and reds the read-backs — which is the
  whole reason they are here.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content

  @dataset "test"

  setup do
    token = "barkpark-dev-token-schema-validate-only-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", "schema-validate-only-test", ["read", "write", "admin"])

    # Unique per test: this dataset is shared with every other suite on the same
    # database, so a fixed name would collide with a peer agent's run.
    name = "svo_widget_#{System.unique_integer([:positive])}"

    %{token: token, name: name}
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp post_schema(ctx, body) do
    build_conn()
    |> authed(ctx.token)
    |> post("/v1/schemas/#{@dataset}", Jason.encode!(body))
  end

  defp valid_body(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => ctx.name,
        "title" => "Validate Only Widget",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string", "required" => true}]
      },
      overrides
    )
  end

  # The read-back. Both doors, because they fail differently: the context read
  # proves no ROW exists, the HTTP read proves no caller can see one.
  defp refute_written!(ctx) do
    assert Content.get_schema(ctx.name, @dataset) == {:error, :not_found},
           "validate_only WROTE a schema row — the whole point of the flag is that it does not"

    resp =
      build_conn()
      |> authed(ctx.token)
      |> get("/v1/schemas/#{@dataset}/#{ctx.name}")

    assert resp.status == 404,
           "validate_only wrote a schema readable over HTTP (status #{resp.status})"
  end

  describe "validate_only: true — a VALID payload" do
    test "answers 200 with the schema it WOULD have written", ctx do
      resp = post_schema(ctx, valid_body(ctx, %{"validate_only" => true}))

      assert resp.status == 200
      body = json_response(resp, 200)

      # Same serializer as the write's 201 echo, so a client can diff a proposed
      # definition against a live one without a round trip through the store.
      assert body["id"] == ctx.name
      assert body["name"] == ctx.name
      assert body["title"] == "Validate Only Widget"
      assert is_binary(body["schemaHash"]) and String.length(body["schemaHash"]) == 16
      assert Enum.find(body["fields"], &(&1["name"] == "title"))["required?"] == true
    end

    test "writes NOTHING — no row, and nothing readable at the show route", ctx do
      assert post_schema(ctx, valid_body(ctx, %{"validate_only" => true})).status == 200

      refute_written!(ctx)
    end

    test "200 not 201 — a `Created` on a row that does not exist would be a lie", ctx do
      resp = post_schema(ctx, valid_body(ctx, %{"validate_only" => true}))

      assert resp.status == 200
      refute resp.status == 201
    end

    test "is repeatable — validating twice still leaves the store empty", ctx do
      assert post_schema(ctx, valid_body(ctx, %{"validate_only" => true})).status == 200
      assert post_schema(ctx, valid_body(ctx, %{"validate_only" => true})).status == 200

      refute_written!(ctx)
    end
  end

  describe "validate_only: true — a REFUSED payload answers exactly what the write answers" do
    test "a structurally-invalid field payload is the same 422, and writes nothing", ctx do
      bad = valid_body(ctx, %{"fields" => [%{"type" => "string"}]})

      dry = post_schema(ctx, Map.put(bad, "validate_only", true))

      assert dry.status == 422
      dry_body = json_response(dry, 422)
      assert dry_body["error"]["code"] == "validation_failed"
      assert dry_body["error"]["details"]["reason"] =~ "field missing name"

      refute_written!(ctx)

      # …and the WRITE door answers the same thing, so a green verdict from the
      # validate-only door genuinely predicts the write. A validate-only mode
      # with its own private refusal set is worse than none.
      wet = post_schema(ctx, bad)
      assert wet.status == dry.status
      assert json_response(wet, 422)["error"]["code"] == dry_body["error"]["code"]

      refute_written!(ctx)
    end

    test "a changeset-invalid payload (no title) is refused and writes nothing", ctx do
      dry =
        post_schema(ctx, %{
          "name" => ctx.name,
          "visibility" => "public",
          "fields" => [],
          "validate_only" => true
        })

      assert dry.status == 422
      refute_written!(ctx)
    end

    test "an out-of-vocabulary visibility is refused and writes nothing", ctx do
      dry = post_schema(ctx, valid_body(ctx, %{"visibility" => "semi", "validate_only" => true}))

      assert dry.status == 422
      refute_written!(ctx)
    end
  end

  describe "validate_only: true — against an EXISTING schema" do
    test "the stored definition is unchanged, byte for byte", ctx do
      assert post_schema(ctx, valid_body(ctx)).status == 201
      {:ok, before} = Content.get_schema(ctx.name, @dataset)

      dry =
        post_schema(
          ctx,
          valid_body(ctx, %{
            "title" => "A TITLE THAT MUST NEVER LAND",
            "fields" => [%{"name" => "body", "type" => "text"}],
            "validate_only" => true
          })
        )

      assert dry.status == 200
      # The verdict describes the PROPOSED schema — that is what makes it useful.
      assert json_response(dry, 200)["title"] == "A TITLE THAT MUST NEVER LAND"

      {:ok, after_dry} = Content.get_schema(ctx.name, @dataset)

      assert after_dry.title == before.title
      assert after_dry.fields == before.fields

      assert after_dry.updated_at == before.updated_at,
             "validate_only touched the row — even an identical rewrite is a write"
    end

    test "an UPDATE is validated as an update: a partial payload is not a missing-title 422",
         ctx do
      assert post_schema(ctx, valid_body(ctx)).status == 201

      # No "title" key at all. Validated against a blank struct this would trip
      # validate_required([:name, :title]); validated against the stored row —
      # which is what the write would do — it is a legitimate partial update.
      dry =
        post_schema(ctx, %{
          "name" => ctx.name,
          "icon" => "star",
          "validate_only" => true
        })

      assert dry.status == 200
      assert json_response(dry, 200)["title"] == "Validate Only Widget"
    end
  end

  describe "NEGATIVE ARM — the write path is untouched" do
    test "no validate_only key at all still writes and answers 201", ctx do
      resp = post_schema(ctx, valid_body(ctx))

      assert resp.status == 201
      assert {:ok, _} = Content.get_schema(ctx.name, @dataset)
    end

    test "validate_only: false writes, exactly as before", ctx do
      resp = post_schema(ctx, valid_body(ctx, %{"validate_only" => false}))

      assert resp.status == 201
      assert {:ok, _} = Content.get_schema(ctx.name, @dataset)
    end

    test "validate_only is never persisted as a schema attribute", ctx do
      assert post_schema(ctx, valid_body(ctx, %{"validate_only" => false})).status == 201

      {:ok, schema} = Content.get_schema(ctx.name, @dataset)
      refute Map.has_key?(Map.from_struct(schema), :validate_only)
      refute Enum.any?(schema.fields || [], &(Map.get(&1, "name") == "validate_only"))
    end

    test "the string \"true\" and \"1\" both mean validate-only, like ?force=", ctx do
      assert post_schema(ctx, valid_body(ctx, %{"validate_only" => "true"})).status == 200
      refute_written!(ctx)

      assert post_schema(ctx, valid_body(ctx, %{"validate_only" => "1"})).status == 200
      refute_written!(ctx)
    end

    test "validate_only rides the query string too", ctx do
      resp =
        build_conn()
        |> authed(ctx.token)
        |> post("/v1/schemas/#{@dataset}?validate_only=true", Jason.encode!(valid_body(ctx)))

      assert resp.status == 200
      refute_written!(ctx)
    end
  end
end
