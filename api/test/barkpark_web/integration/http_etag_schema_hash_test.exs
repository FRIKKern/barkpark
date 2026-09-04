defmodule BarkparkWeb.Integration.HttpEtagSchemaHashTest do
  @moduledoc """
  A SCHEMA edit must move the query/doc ETag (task-496f010fa8f4d9dc).

  ## The defect this pins

  PR #14042 withdrew the validator on every SHAPED (`?fields=`/`?expand=`/
  `?resolve=`) and PRINCIPAL-BOUND read. That left exactly one branch still
  emitting an ETag — anonymous + unshaped — and on that branch the validator was
  folded from `dataset|type|_id:_rev,…` (list) or the bare `_rev` (doc).

  The body on that same branch is built by `Barkpark.Content.Envelope.render/3`,
  whose per-field redaction reads the SCHEMA's `private` / `visibility` /
  `readable_by` attributes. `Barkpark.Content.Schema.upsert_schema/3` writes the
  SchemaDefinition row and touches NO document, so marking a field `private`
  moved no `_rev` — the recomputed validator was byte-identical. An anonymous
  caller replaying its pre-edit ETag got **304 with an empty body** and kept
  serving the field the schema now hides, plus a stale envelope `schemaHash`.

  Fail-OPEN: the field seal is applied at render time, and the conditional
  branch routes around render entirely.

  ## The fix under test

  `cache_validator/2` folds `Content.schema_hash_for_dataset/2` — the value the
  envelope already carries as `schemaHash`, now computed once per request and
  threaded down instead of re-read in `envelope/5` — on top of the document
  token, and the HEADER plus the If-None-Match compare use that.

  The envelope BODY's `etag` is deliberately NOT folded. It is a documented SDK
  contract: `js/packages/core/src/doc.ts` returns it as `DocResult.etag`
  ("Unquoted ETag ( = document _rev). Pass back as ifMatch on writes") and
  `Content.Mutations.if_rev/1` compares `ifMatch` to the stored rev, so folding
  anything into it would turn every documented read-then-write into a 412. The
  two-token split is pinned by its own test below.

  ## Mutation proof

  Make `cache_validator/2` return its `etag` argument unchanged: both
  `must answer 200` tests red with `304`.

  Two non-vacuity controls guard every pin: the field IS present in the first
  read (so a broken fixture cannot pass), and the two `schemaHash` values DIFFER
  (so a hash that never moved cannot pass).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "http_etag_schema_hash_test"
  @type_name "employee"
  @doc_id "hesh-00001"

  defp upsert_type!(fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Employee",
          "visibility" => "public",
          "fields" => fields
        },
        @ds
      )
  end

  defp public_salary_field, do: [%{"name" => "salary", "type" => "string"}]
  defp private_salary_field, do: [%{"name" => "salary", "type" => "string", "private" => true}]

  setup do
    upsert_type!(public_salary_field())

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => @doc_id, "title" => "an employee", "salary" => "1000000"},
        @ds
      )

    {:ok, _} = Content.publish_document(@doc_id, @type_name, @ds)

    :ok
  end

  defp doc_path, do: "/v1/data/doc/#{@ds}/#{@type_name}/#{@doc_id}"
  defp list_path, do: "/v1/data/query/#{@ds}/#{@type_name}"

  # Mirrors QueryController.cache_validator/2 — the test asserts the header IS
  # this value, so a change to the fold reds here too rather than silently
  # passing an "it is not the rev" check.
  defp cache_validator(etag, schema_hash) do
    :crypto.hash(:sha256, "#{etag}|#{schema_hash}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp etag_of(conn) do
    [etag] = get_resp_header(conn, "etag")
    etag
  end

  describe "the list route — GET /v1/data/query/:dataset/:type" do
    test "a field newly marked private must not be served out of a pre-edit 304" do
      first = get(scoped_conn(), list_path())
      assert first.status == 200, "request never arrived (status #{first.status})"
      body = json_response(first, 200)

      # CONTROL 1 — the fixture is not vacuous: the field really shipped.
      assert [%{"salary" => "1000000"}] = body["result"]["documents"]
      etag = etag_of(first)
      hash_before = body["schemaHash"]
      assert is_binary(hash_before)

      # The same ETag replayed with the schema UNCHANGED still 304s — otherwise
      # the pin below could pass because 304 never happens on this route.
      unchanged = get(put_req_header(scoped_conn(), "if-none-match", etag), list_path())
      assert unchanged.status == 304

      upsert_type!(private_salary_field())

      replay = get(put_req_header(scoped_conn(), "if-none-match", etag), list_path())

      assert replay.status == 200,
             "a schema visibility edit answered #{replay.status} from a pre-edit validator"

      after_body = json_response(replay, 200)
      assert [doc] = after_body["result"]["documents"]
      refute Map.has_key?(doc, "salary"), "the now-private field was served anyway"

      # CONTROL 2 — the schema hash really moved, so the pin above is not
      # passing on some unrelated change to the validator.
      assert after_body["schemaHash"] != hash_before
    end
  end

  describe "the two tokens are SEPARATE (body etag = ifMatch, header = cache validator)" do
    # MUTATION PROOF: fold the schema hash into `doc_etag/2` as well (i.e. put
    # the validator in the body) and this reds — which is exactly the 412 a
    # documented `DocResult.etag` -> `ifMatch` round-trip would hit.
    test "the doc route's BODY etag is still the bare document _rev" do
      resp = get(scoped_conn(), doc_path())
      assert resp.status == 200, "request never arrived (status #{resp.status})"
      body = json_response(resp, 200)

      rev = body["result"]["_rev"]
      assert is_binary(rev) and rev != ""
      assert body["etag"] == rev, "the body etag is the SDK ifMatch token — it must stay the _rev"

      # …while the HTTP validator has moved off the rev, because it must also
      # answer to the schema.
      header = etag_of(resp)
      assert header == ~s("#{cache_validator(rev, body["schemaHash"])}")
      refute header == ~s("#{rev}")
    end

    test "the list route's BODY etag is still main's ids/revs fold, not the validator" do
      resp = get(scoped_conn(), list_path())
      assert resp.status == 200, "request never arrived (status #{resp.status})"
      body = json_response(resp, 200)

      assert is_binary(body["etag"])
      assert etag_of(resp) == ~s("#{cache_validator(body["etag"], body["schemaHash"])}")
      refute etag_of(resp) == ~s("#{body["etag"]}")
    end
  end

  describe "the doc route — GET /v1/data/doc/:dataset/:type/:id" do
    test "a field newly marked private must not be served out of a pre-edit 304" do
      first = get(scoped_conn(), doc_path())
      assert first.status == 200, "request never arrived (status #{first.status})"
      body = json_response(first, 200)

      # CONTROL 1 — the fixture is not vacuous.
      assert body["result"]["salary"] == "1000000"
      etag = etag_of(first)
      hash_before = body["schemaHash"]
      assert is_binary(hash_before)

      unchanged = get(put_req_header(scoped_conn(), "if-none-match", etag), doc_path())
      assert unchanged.status == 304

      upsert_type!(private_salary_field())

      replay = get(put_req_header(scoped_conn(), "if-none-match", etag), doc_path())

      assert replay.status == 200,
             "a schema visibility edit answered #{replay.status} from a pre-edit validator"

      after_body = json_response(replay, 200)

      refute Map.has_key?(after_body["result"], "salary"),
             "the now-private field was served anyway"

      # CONTROL 2 — the schema hash really moved.
      assert after_body["schemaHash"] != hash_before
    end
  end
end
