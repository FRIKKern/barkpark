defmodule BarkparkWeb.EnvelopeGlobalSchemaRedactionTest do
  @moduledoc """
  Field-visibility scar-class, Scenario B (felix-w30-s1). The render-time
  redaction chokepoint (`Content.Envelope.render/3`) is LENIENT on a nil
  schema — with `schema == nil` it drops only encrypted ciphertext, so a
  NON-encrypted `private` field renders PUBLIC. `query_controller.fetch_schema/3`
  resolves the redaction schema under the request's workspace-ONLY scope, so a
  GLOBAL (workspace_id = nil) schema MISSES at the render site and its private
  field would leak to a non-admin reader token via `/v1/data/query`.

  The fix mirrors `content/papers.ex value_schema/3`: on the scoped miss,
  fetch_schema retries with `:workspace_id`/`:project_id` stripped and accepts
  the result ONLY when `workspace_id` is nil — the global schema. The stripped
  scope reads cross-tenant rows, so that nil-workspace guard is LOAD-BEARING:
  accepting any non-nil workspace would substitute a FOREIGN tenant's schema.

  FAIL-BEFORE (proven manually before commit): reverting fetch_schema/3 to the
  nil-on-miss form REDS the "global schema … is REDACTED" test below (the ssn
  field leaks in the reader-token body); restoring the fallback GREENS it. The
  co-resident and schemaless rows guard against over-redaction and legacy
  schemaless=public parity respectively.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Content.SchemaDefinition

  @prod "production"

  @uniq System.unique_integer([:positive])
  @ds_global "gsr_global_#{@uniq}"
  @ds_local "gsr_local_#{@uniq}"
  @ds_none "gsr_none_#{@uniq}"

  @admin_token "gsr-admin-#{@uniq}"
  @reader_token "gsr-reader-#{@uniq}"

  # The legacy twin's type. LegacyController reads `production` ONLY, so this
  # fixture lives there rather than in a per-test dataset.
  @legacy_type "gsrlegacy#{@uniq}"

  setup do
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: project.id]

    # ── Scenario B: a GLOBAL (workspace_id = nil) schema declaring a
    #    NON-encrypted private "ssn". put_scope_attrs forces server scope on any
    #    request/facade write, so a nil-workspace schema is created by a direct
    #    Repo.insert! — the sanctioned test setup for a global fixture.
    Repo.insert!(%SchemaDefinition{
      name: "gsrglobal",
      title: "Global Report",
      visibility: "public",
      dataset: @ds_global,
      workspace_id: nil,
      project_id: nil,
      dataset_id: nil,
      fields: [
        %{"name" => "name", "type" => "string"},
        %{"name" => "ssn", "type" => "string", "private" => true, "encrypted" => false}
      ]
    })

    {:ok, _} =
      Content.create_document(
        "gsrglobal",
        %{"_id" => "gsr-b-1", "title" => "B", "content" => %{"name" => "bob", "ssn" => "LEAK-B"}},
        @ds_global,
        scope
      )

    {:ok, _} = Content.publish_document("gsr-b-1", "gsrglobal", @ds_global, scope)

    # ── Guard: a CO-RESIDENT schema (same workspace scope as the doc) declaring
    #    a private "ssn" must still redact — the fix must not break the normal
    #    scoped-hit path (no over/under-redaction regression).
    Content.upsert_schema(
      %{
        "name" => "gsrlocal",
        "title" => "Local Report",
        "visibility" => "public",
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "ssn", "type" => "string", "private" => true}
        ]
      },
      @ds_local
    )

    {:ok, _} =
      Content.create_document(
        "gsrlocal",
        %{"_id" => "gsr-l-1", "title" => "L", "content" => %{"name" => "lee", "ssn" => "CORES"}},
        @ds_local,
        scope
      )

    {:ok, _} = Content.publish_document("gsr-l-1", "gsrlocal", @ds_local, scope)

    # ── Guard: a SCHEMALESS type (no schema anywhere) stays PUBLIC — legacy
    #    schemaless=public parity. The fix must not over-redact where there is
    #    no schema at all.
    {:ok, _} =
      Content.create_document(
        "gsrnone",
        %{"_id" => "gsr-n-1", "title" => "N", "content" => %{"name" => "nan", "ssn" => "PLAIN"}},
        @ds_none,
        scope
      )

    {:ok, _} = Content.publish_document("gsr-n-1", "gsrnone", @ds_none, scope)

    # ── Scenario B, LEGACY TWIN (task-9b51772bc9fd8ec4). `LegacyController` is
    #    pinned to `@dataset "production"` (legacy_controller.ex:15), so the
    #    per-test datasets above are unreachable on `/api/documents/:type` and a
    #    fixture in `production` is the only way to exercise that twin. Same
    #    shape as the global fixture: a workspace_id: nil schema declaring a
    #    NON-encrypted private "ssn", and a published document carrying it.
    Repo.insert!(%SchemaDefinition{
      name: @legacy_type,
      title: "Legacy Global Report",
      visibility: "public",
      dataset: @prod,
      workspace_id: nil,
      project_id: nil,
      dataset_id: nil,
      fields: [
        %{"name" => "name", "type" => "string"},
        %{"name" => "ssn", "type" => "string", "private" => true, "encrypted" => false}
      ]
    })

    {:ok, _} =
      Content.create_document(
        @legacy_type,
        %{
          "_id" => "gsr-legacy-1",
          "title" => "LEG",
          "content" => %{"name" => "lex", "ssn" => "LEAK-LEGACY"}
        },
        @prod,
        scope
      )

    {:ok, _} = Content.publish_document("gsr-legacy-1", @legacy_type, @prod, scope)

    {:ok, _} = Auth.create_token(@admin_token, "gsr admin", @prod, ["admin"])
    {:ok, _} = Auth.create_token(@reader_token, "gsr reader", @prod, ["read", "write"])

    :ok
  end

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp query_doc(conn, dataset, type, id) do
    body =
      conn
      |> get("/v1/data/query/#{dataset}/#{type}")
      |> json_response(200)

    Enum.find(body["result"]["documents"], &(&1["_id"] == id))
  end

  # The legacy twin's list route. Its wire shape nests surviving content fields
  # under "values" (legacy_controller.render_legacy_doc/3), so callers assert on
  # doc["values"]["ssn"] rather than doc["ssn"].
  defp legacy_doc(conn, type, id) do
    body =
      conn
      |> get("/api/documents/#{type}")
      |> json_response(200)

    Enum.find(body["documents"], &(&1["id"] == id))
  end

  describe "global (workspace_id: nil) schema redaction on /v1/data/query" do
    test "non-admin reader does NOT see the global schema's private field", %{conn: conn} do
      doc = query_doc(bearer(conn, @reader_token), @ds_global, "gsrglobal", "gsr-b-1")

      assert doc["name"] == "bob"
      # THE FIX: without the global-schema fallback in fetch_schema/3 this leaks.
      refute Map.has_key?(doc, "ssn")
    end

    test "admin DOES see the global schema's private field (redaction is caller-scoped)",
         %{conn: conn} do
      doc = query_doc(bearer(conn, @admin_token), @ds_global, "gsrglobal", "gsr-b-1")

      assert doc["ssn"] == "LEAK-B"
    end

    test "anonymous read of a global-schema-only type stays 404 (anon gating untouched)",
         %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds_global}/gsrglobal")
      assert resp.status == 404
    end
  end

  describe "the LEGACY twin — /api/documents/:type (task-9b51772bc9fd8ec4)" do
    # THE DUPLICATED-RENDER-PATH HAZARD. `query_controller.fetch_schema/3` was
    # given the global-schema fallback; `legacy_controller.fetch_schema/2` was
    # not. Same schema, same document, same token — one twin redacted and the
    # other served the private field. Reachable with an ordinary `read`-tier
    # token, the lowest credential in the system.
    test "non-admin reader does NOT see the global schema's private field", %{conn: conn} do
      doc = legacy_doc(bearer(conn, @reader_token), @legacy_type, "gsr-legacy-1")

      assert get_in(doc, ["values", "name"]) == "lex"

      refute Map.has_key?(doc["values"] || %{}, "ssn"),
             "the legacy render path served a globally-declared private field: #{inspect(doc)}"
    end

    test "admin DOES see it — redaction stays caller-scoped on this twin too",
         %{conn: conn} do
      doc = legacy_doc(bearer(conn, @admin_token), @legacy_type, "gsr-legacy-1")

      assert get_in(doc, ["values", "ssn"]) == "LEAK-LEGACY"
    end

    # THE PARITY PIN. Identical input to both twins must produce identical
    # visibility of `ssn`, so the divergence cannot silently reopen: whichever
    # twin regresses, this reds.
    test "both twins agree on `ssn` for the SAME schema, document and token",
         %{conn: conn} do
      legacy = legacy_doc(bearer(conn, @reader_token), @legacy_type, "gsr-legacy-1")
      queried = query_doc(bearer(conn, @reader_token), @prod, @legacy_type, "gsr-legacy-1")

      legacy_has = Map.has_key?(legacy["values"] || %{}, "ssn")
      query_has = Map.has_key?(queried || %{}, "ssn")

      assert legacy_has == query_has,
             "render twins diverged on a private field — legacy shows it: #{legacy_has}, " <>
               "query shows it: #{query_has}"

      refute legacy_has, "both twins leaked the private field"
    end
  end

  describe "guard rows — no over-redaction, no legacy parity break" do
    test "co-resident schema still redacts the private field for a non-admin reader",
         %{conn: conn} do
      doc = query_doc(bearer(conn, @reader_token), @ds_local, "gsrlocal", "gsr-l-1")

      assert doc["name"] == "lee"
      refute Map.has_key?(doc, "ssn")
    end

    test "schemaless type stays public — a field with no schema anywhere is NOT redacted",
         %{conn: conn} do
      doc = query_doc(bearer(conn, @reader_token), @ds_none, "gsrnone", "gsr-n-1")

      assert doc["name"] == "nan"
      assert doc["ssn"] == "PLAIN"
    end
  end
end
