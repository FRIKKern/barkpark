defmodule BarkparkWeb.NonBinaryWriteParam500Test do
  @moduledoc """
  Two write-tier endpoints, one shape (task-0fba128e04ab8aee).

  `Plug.Conn.Query` turns `?x[]=a` into a LIST and `?x[k]=v` into a MAP. Both
  of these actions read a params key that has NO path segment to bind it, with
  `Map.get`, and hand the value three frames down into a function that guards
  `is_binary` — so a caller-controlled query string raised
  `FunctionClauseError` AFTER dispatch and the request 500'd:

    * `POST /api/documents/post?id[]=a` — `LegacyController.create/2` reads
      `Map.get(attrs, "id") || Map.get(attrs, "doc_id")` (a list is truthy),
      `Content.upsert_document/4` does `raw_id && DraftId.draft_id(raw_id)`,
      and `DraftId.draft_id/1` calls `String.starts_with?(["a"], "drafts.")`.
      `?id[k]=v` and `?doc_id[]=a` take the identical path.

    * `POST /v1/plugins/github/adopt/:id?dataset[]=x` —
      `GithubAdoptController.adopt/2` reads
      `Map.get(params, "dataset", "production")` and forwards it to
      `Barkpark.Plugins.Github.Adopt.adopt/3`, whose head is
      `when is_binary(doc_id) and is_binary(dataset)`.

  Both need a write-tier bearer, so neither is anonymous — but the bar is a
  disposable playground token (`["read", "write"]`).

  Each request below is driven through the real router with a real query
  string, so `Plug.Parsers` — not the test — produces the list/map. The
  positive controls in the same run pin that a legitimate binary param still
  reaches its real (non-500) outcome, so the guards are not blanket refusals.
  """
  # sync: calls the named GenServer Barkpark.Plugins.Github.Auth; its sandbox ownership dies under concurrency
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @dataset "production"
  @write_token "nonbin-write-param-write"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_task_schemas!(scope)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} = Auth.create_token(@write_token, "nonbin-write", @dataset, ["read", "write"], ws.id)

    %{scope: scope}
  end

  defp register_task_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @write_token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A clean 4xx with the canonical envelope — never a 500, and never a body
  # that is a rendered stacktrace.
  defp assert_clean_4xx(resp) do
    assert resp.status >= 400 and resp.status < 500,
           "expected a clean 4xx, got #{resp.status} — body: #{resp.resp_body}"

    body = Jason.decode!(resp.resp_body)

    assert %{"error" => %{"code" => code, "message" => message}} = body
    assert is_binary(code)
    assert code != ""
    assert is_binary(message)
    refute String.contains?(resp.resp_body, "FunctionClauseError")
    refute String.contains?(resp.resp_body, "Exception")
    body
  end

  # ── SITE 1: POST /api/documents/:type — `id` / `doc_id` ────────────────────

  describe "LegacyController.create/2 — a non-binary id/doc_id" do
    for {label, qs} <- [
          {"list-valued ?id[]=", "id[]=a"},
          {"map-valued ?id[k]=", "id[k]=v"},
          {"list-valued ?doc_id[]=", "doc_id[]=a"},
          {"map-valued ?doc_id[k]=", "doc_id[k]=v"}
        ] do
      test "POST /api/documents/post?#{qs} (#{label}) is a clean 4xx, not a 500", %{conn: conn} do
        resp =
          conn
          |> authed()
          |> post(
            "/api/documents/post?" <> unquote(qs),
            Jason.encode!(%{"title" => "non-binary probe"})
          )

        refute resp.status == 500
        assert_clean_4xx(resp)
      end
    end

    test "POSITIVE CONTROL — a binary id still creates the document (201)", %{conn: conn} do
      id = uniq("lc-ok")

      resp =
        conn
        |> authed()
        |> post("/api/documents/post", Jason.encode!(%{"id" => id, "title" => "ok"}))

      assert resp.status == 201, "control returned #{resp.status} — body: #{resp.resp_body}"
      assert %{"id" => "drafts." <> _} = json_response(resp, 201)
    end

    test "POSITIVE CONTROL — a binary doc_id still creates the document (201)", %{conn: conn} do
      id = uniq("lc-ok-docid")

      resp =
        conn
        |> authed()
        |> post("/api/documents/post", Jason.encode!(%{"doc_id" => id, "title" => "ok"}))

      assert resp.status == 201, "control returned #{resp.status} — body: #{resp.resp_body}"
    end
  end

  # ── SITE 2: POST /v1/plugins/github/adopt/:id — `dataset` ─────────────────

  describe "GithubAdoptController.adopt/2 — a non-binary dataset" do
    setup %{scope: scope} do
      %{task: open_intake_task!(scope)}
    end

    for {label, qs} <- [
          {"list-valued ?dataset[]=", "dataset[]=x"},
          {"map-valued ?dataset[k]=", "dataset[k]=v"}
        ] do
      test "POST /v1/plugins/github/adopt/:id?#{qs} (#{label}) is a clean 4xx, not a 500",
           %{conn: conn, task: task} do
        resp =
          conn
          |> authed()
          |> post(
            "/v1/plugins/github/adopt/#{task.doc_id}?" <> unquote(qs),
            Jason.encode!(%{})
          )

        refute resp.status == 500
        assert_clean_4xx(resp)
      end
    end

    test "POSITIVE CONTROL — a binary dataset still adopts (200, state flips)",
         %{conn: conn, task: task, scope: scope} do
      resp =
        conn
        |> authed()
        |> post(
          "/v1/plugins/github/adopt/#{task.doc_id}?dataset=#{@dataset}",
          Jason.encode!(%{})
        )

      assert resp.status == 200, "control returned #{resp.status} — body: #{resp.resp_body}"
      assert github_state(reload!(task.doc_id, scope)) == "adopted"
    end

    # Uses the setup's task: the task birth fence rejects a near-duplicate
    # title, so a test that births a SECOND intake fixture fails in setup
    # rather than in the assertion under test.
    test "POSITIVE CONTROL — an absent dataset still defaults to production and adopts",
         %{conn: conn, task: task, scope: scope} do
      resp =
        conn
        |> authed()
        |> post("/v1/plugins/github/adopt/#{task.doc_id}", Jason.encode!(%{}))

      assert resp.status == 200, "control returned #{resp.status} — body: #{resp.resp_body}"
      assert github_state(reload!(task.doc_id, scope)) == "adopted"
    end

    # `:id` is bound by the path segment, so the router can only ever hand the
    # action a binary — but the action guards it anyway (Adopt.adopt/3's head
    # requires BOTH args to be binaries). Driven at the action, since no query
    # string can reach this branch through today's mounts.
    test "a non-binary :id is a clean 400 at the action, not a raise" do
      conn = BarkparkWeb.GithubAdoptController.adopt(scoped_conn(), %{"id" => ["gh-1"]})

      assert %{"error" => %{"code" => "malformed"}} = json_response(conn, 400)
    end
  end

  # An unclaimed `src:github` intake task — `content.github.state == "intake"`
  # is the only fact `Adopt.adopt/3` reads to decide adoptability.
  # NOTE: the title is uniquified too — the task birth fence rejects a second
  # task whose title matches an existing one (`:duplicate_task`), so a fixed
  # title makes the SECOND fixture in a run blow up in setup rather than in
  # the assertion under test.
  defp open_intake_task!(scope) do
    id = uniq("gh-nonbin")

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => id,
          "title" => "non-binary dataset probe intake #{id}",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "labels" => ["src:github", "needs-human"],
            "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 1, "state" => "intake"}
          }
        },
        @dataset,
        scope
      )

    task
  end

  defp reload!(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  defp github_state(doc), do: get_in(doc.content, ["github", "state"])
end
