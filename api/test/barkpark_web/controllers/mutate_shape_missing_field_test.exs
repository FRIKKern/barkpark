defmodule BarkparkWeb.MutateShapeMissingFieldTest do
  @moduledoc """
  #18, Gyldendal field report — a mutation verb sent with the WRONG SHAPE names
  the field it is missing.

  `publish`, `unpublish`, `discardDraft`, `delete` and `patch` all require
  `{id, type}`: every one of those `apply_one/3` heads pattern-matches
  `%{"id" => id, "type" => type}` (content/mutations.ex). A payload missing
  either key matches NO head and falls to the catch-all, which answered a bare
  400 `{"code":"malformed","message":"request body is malformed"}` — no field,
  no verb, nothing to act on. Gyldendal read the shapes out of mutations.ex to
  get past it.

  THE VERB SET IS DERIVED FROM THE CODE, not from the row: it is exactly the
  set of `apply_one/3` heads whose payload pattern is `%{"id" => _, "type" =>
  _}`. The row named three of the five.

  DELIBERATELY NARROW. A body that is not a mutation at all — an unknown verb,
  a non-map payload under a known verb — is GENUINELY malformed and keeps the
  400. The 422 fires only when a known {id,type} verb was sent as a map that
  simply omitted one of the two required keys, which is a well-formed request
  the server cannot act on as sent — the meaning 422 already carries in this
  codebase (see the `workspace_scope_required` note in content/errors.ex).

  RED-BEFORE on origin/main (fd6e9ddff): every `422` assertion below failed on
  `status == 400` / `code == "malformed"`; the two NEGATIVE-arm tests (unknown
  verb, non-map payload) passed before and after — they are the guard on the
  fix, not the proof of the defect.

  SHARED TEST DATABASE: no assertion here counts rows or reads a table. Each
  request is refused before any document is written, so no other agent's rows
  can reach these assertions.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token("barkpark-shape-token", "shape", "test", ["read", "write"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  defp mutate(conn, mutation) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-shape-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", Jason.encode!(%{"mutations" => [mutation]}))
  end

  defp error(resp), do: Jason.decode!(resp.resp_body)["error"]

  # ── The 422 names the verb AND the field ────────────────────────────────────

  test "publish without type answers 422 naming type", %{conn: conn} do
    resp = mutate(conn, %{"publish" => %{"id" => "x"}})

    assert resp.status == 422
    err = error(resp)
    assert err["code"] == "validation_failed"
    assert err["message"] == "publish requires both id and type; missing: type"
    assert err["details"]["mutation"] == "publish"
    assert err["details"]["missing"] == ["type"]
  end

  test "publish without id answers 422 naming id", %{conn: conn} do
    resp = mutate(conn, %{"publish" => %{"type" => "post"}})

    assert resp.status == 422
    assert error(resp)["message"] == "publish requires both id and type; missing: id"
  end

  test "delete with an empty payload names BOTH missing fields", %{conn: conn} do
    resp = mutate(conn, %{"delete" => %{}})

    assert resp.status == 422
    err = error(resp)
    assert err["message"] == "delete requires both id and type; missing: id, type"
    assert err["details"]["missing"] == ["id", "type"]
  end

  test "unpublish without type answers 422 naming unpublish and type", %{conn: conn} do
    resp = mutate(conn, %{"unpublish" => %{"id" => "x"}})

    assert resp.status == 422
    assert error(resp)["message"] == "unpublish requires both id and type; missing: type"
  end

  test "discardDraft without id answers 422 naming discardDraft and id", %{conn: conn} do
    resp = mutate(conn, %{"discardDraft" => %{"type" => "post"}})

    assert resp.status == 422
    assert error(resp)["message"] == "discardDraft requires both id and type; missing: id"
  end

  test "patch without type answers 422 naming patch and type", %{conn: conn} do
    resp = mutate(conn, %{"patch" => %{"id" => "x", "set" => %{"title" => "t"}}})

    assert resp.status == 422
    assert error(resp)["message"] == "patch requires both id and type; missing: type"
  end

  # BOUNDARY, pinned so the next reader does not mistake it for an oversight: a
  # key that is PRESENT but blank matches the `publish` head above the catch-all
  # and is resolved as an id, so it 404s on the lookup and never reaches this
  # refusal. Widening that would mean editing the verb heads themselves, which
  # is a different change with a different blast radius (every verb's happy
  # path). The catch-all's own emptiness check is kept as a superset so the
  # refusal stays correct if a head is ever relaxed.
  test "a present-but-blank id still 404s at the lookup — the heads own that case",
       %{conn: conn} do
    resp = mutate(conn, %{"publish" => %{"id" => "  ", "type" => "post"}})

    assert resp.status == 404
    refute error(resp)["code"] == "malformed"
  end

  # ── NEGATIVE ARM: genuinely malformed bodies keep the generic 400 ───────────

  test "an unknown verb is still a bare 400 malformed", %{conn: conn} do
    resp = mutate(conn, %{"frobnicate" => %{"id" => "x", "type" => "post"}})

    assert resp.status == 400
    err = error(resp)
    assert err["code"] == "malformed"
    assert err["message"] == "request body is malformed"
  end

  test "a known verb whose payload is not a map is still a bare 400", %{conn: conn} do
    resp = mutate(conn, %{"publish" => "x"})

    assert resp.status == 400
    assert error(resp)["code"] == "malformed"
  end

  test "a patch carrying id and type but no recognized op stays a bare 400", %{conn: conn} do
    resp = mutate(conn, %{"patch" => %{"id" => "x", "type" => "post"}})

    assert resp.status == 400
    assert error(resp)["code"] == "malformed"
  end
end
