defmodule BarkparkWeb.Integration.SchemaAdminTest do
  @moduledoc """
  Integration probe for the admin-only schema CRUD surface (Goal
  `barkpark-b1m`, Task `barkpark-upn`, gap #3).

  Pre-s7 coverage: zero. `schema_test.exs` (38 LOC) and
  `schema_envelope_test.exs` covered only the GET side. Neither POST upsert
  nor DELETE was exercised end-to-end — yet both run through
  `:require_admin` and the upsert is the path plugin schemas (e.g.
  OnixEdit's `book`) land through.

  This file closes the write side:

    * `POST /v1/schemas/:dataset` with admin token + valid body → 201
    * `POST` without token → 401
    * `POST` with valid body but non-admin token → 403
    * `POST` with malformed body (missing required `title`) → 422
    * `DELETE /v1/schemas/:dataset/:name` with admin → 200, GET → 404 after
    * `DELETE` with non-admin → 403
    * `DELETE` of an unknown schema → 404

  `async: false` because the upserts mutate the shared `schema_definitions`
  table for the `test` dataset and the dev token, mirroring every other
  schema_*_test.exs in the suite. Created schemas are cleaned up in
  `on_exit`.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @admin_token "barkpark-dev-token"
  @reader_token "barkpark-reader-token-schema-admin"

  setup do
    Auth.create_token(@admin_token, "dev", "schema-admin-integration", ["read", "write", "admin"])
    # A read-only token to assert the 403 path on admin-gated routes.
    Auth.create_token(@reader_token, "dev", "schema-admin-integration-reader", ["read"])

    # Drain the boot-time codelist seeder Task before grabbing the DB —
    # otherwise it can hog the sandbox connection and our setup blows up.
    drain_task_supervisor(30_000)

    # DB rows are rolled back by the SQL sandbox — no manual cleanup needed.
    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  # ── POST /v1/schemas/:dataset ────────────────────────────────────────────

  describe "POST /v1/schemas/:dataset — upsert" do
    test "with admin token + valid body → 201 + the schema becomes readable",
         %{conn: conn} do
      body = %{
        "name" => "widget",
        "title" => "Widget",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      }

      resp =
        conn
        |> authed(@admin_token)
        |> post(~p"/v1/schemas/test", Jason.encode!(body))

      assert resp.status == 201

      created = json_response(resp, 201)
      assert created["name"] == "widget"
      assert created["title"] == "Widget"

      # Read it back via the index. The envelope wraps schemas under `schemas`.
      list =
        conn
        |> authed(@admin_token)
        |> get(~p"/v1/schemas/test")
        |> json_response(200)

      names = Enum.map(list["schemas"], & &1["name"])
      assert "widget" in names
    end

    test "without a token → 401", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/v1/schemas/test",
          Jason.encode!(%{"name" => "x", "title" => "X", "fields" => []})
        )

      assert resp.status == 401
    end

    test "with a non-admin token → 403", %{conn: conn} do
      resp =
        conn
        |> authed(@reader_token)
        |> post(
          ~p"/v1/schemas/test",
          Jason.encode!(%{"name" => "x", "title" => "X", "fields" => []})
        )

      assert resp.status == 403
    end

    test "with a malformed body (missing `title`) → 422", %{conn: conn} do
      resp =
        conn
        |> authed(@admin_token)
        |> post(~p"/v1/schemas/test", Jason.encode!(%{"name" => "no_title", "fields" => []}))

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"
    end
  end

  # ── DELETE /v1/schemas/:dataset/:name ────────────────────────────────────

  describe "DELETE /v1/schemas/:dataset/:name" do
    test "with admin token → 200 + subsequent GET returns 404", %{conn: conn} do
      # Create one we can drop.
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "deletable", "title" => "Deletable", "fields" => []},
          "test"
        )

      resp =
        conn
        |> authed(@admin_token)
        |> delete(~p"/v1/schemas/test/deletable")

      assert resp.status == 200
      assert %{"deleted" => "deletable"} = json_response(resp, 200)

      show =
        conn
        |> authed(@admin_token)
        |> get(~p"/v1/schemas/test/deletable")

      assert show.status == 404
    end

    test "with a non-admin token → 403", %{conn: conn} do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "guarded", "title" => "Guarded", "fields" => []},
          "test"
        )

      resp =
        conn
        |> authed(@reader_token)
        |> delete(~p"/v1/schemas/test/guarded")

      assert resp.status == 403

      # Still there — the delete was forbidden, not silently no-op'd.
      assert {:ok, _} = Content.get_schema("guarded", "test")
    end

    test "unknown schema → 404", %{conn: conn} do
      resp =
        conn
        |> authed(@admin_token)
        |> delete(~p"/v1/schemas/test/does-not-exist")

      assert resp.status == 404
    end

    test "with existing documents of the type → 409 schema_has_documents (no orphaning)",
         %{conn: conn} do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "populated", "title" => "Populated", "visibility" => "public", "fields" => []},
          "test"
        )

      {:ok, _} = Content.create_document("populated", %{"_id" => "pop-1", "title" => "Doc 1"}, "test")
      {:ok, _} = Content.create_document("populated", %{"_id" => "pop-2", "title" => "Doc 2"}, "test")

      resp =
        conn
        |> authed(@admin_token)
        |> delete(~p"/v1/schemas/test/populated")

      assert resp.status == 409
      body = json_response(resp, 409)
      assert body["error"]["code"] == "schema_has_documents"
      assert body["error"]["details"]["count"] == 2

      # The refusal must be real — the schema is still there.
      assert {:ok, _} = Content.get_schema("populated", "test")
    end

    test "with existing documents + ?force=true → 200 (orphans them deliberately)",
         %{conn: conn} do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "forced", "title" => "Forced", "visibility" => "public", "fields" => []},
          "test"
        )

      {:ok, _} = Content.create_document("forced", %{"_id" => "f-1", "title" => "Doc 1"}, "test")

      resp =
        conn
        |> authed(@admin_token)
        |> delete(~p"/v1/schemas/test/forced?force=true")

      assert resp.status == 200
      assert %{"deleted" => "forced"} = json_response(resp, 200)
      assert {:error, :not_found} = Content.get_schema("forced", "test")
    end

    test "empty-type schema deletes without force → 200", %{conn: conn} do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "empty", "title" => "Empty", "fields" => []},
          "test"
        )

      resp =
        conn
        |> authed(@admin_token)
        |> delete(~p"/v1/schemas/test/empty")

      assert resp.status == 200
      assert %{"deleted" => "empty"} = json_response(resp, 200)
    end
  end
end
