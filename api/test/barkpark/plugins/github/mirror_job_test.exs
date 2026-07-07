defmodule Barkpark.Plugins.Github.MirrorJobTest do
  @moduledoc """
  Wave-2 slice-1: the outbound `MirrorJob.reconcile/2` heart (epic D2/D3/D7/D9).

  Exercises reconcile directly against a REAL task doc (created via `Content`)
  and a MOCKED GitHub (Bypass — the `client_test.exs` pattern): create →
  issue# stamped in `content.github`; idempotent update PATCH (open / close
  completed / close not_planned); the full contract-#3 error map
  (422→cancel, 429→snooze, 5xx→error, 404-on-update→detached); the
  already-synced and detached-link short-circuits; plus one `perform_job/2`
  smoke to prove the Oban args wiring.
  """

  # async: false — Auth is a singleton GenServer and we mutate Application env.
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Github.{Auth, Link, MirrorJob}

  @dataset "production"
  @app_id "123456"
  @installation_id "987654"
  @repo "FRIKKern/barkpark"
  @inst_token "ghs_installation_token_abc123"
  @token_path "/app/installations/#{@installation_id}/access_tokens"

  setup do
    Process.flag(:trap_exit, true)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    # Throwaway RSA keypair — NO real GitHub App credentials exist.
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    prior = Application.get_env(:barkpark, Barkpark.Plugins.Github)

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Github,
      app_id: @app_id,
      installation_id: @installation_id,
      private_key: pem,
      repo: @repo,
      api_base: base,
      github_api_base: base
    )

    start_supervised!(Auth)
    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.Github, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Github)
      end
    end)

    {:ok, bypass: bypass, base: base, scope: scope}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, content, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => Map.get(content, "title", doc_id),
          "content" => Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content)
        },
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp stub_token(bypass) do
    Bypass.stub(bypass, "POST", @token_path, fn conn ->
      Plug.Conn.resp(conn, 201, Jason.encode!(%{"token" => @inst_token, "expires_in" => 3600}))
    end)
  end

  defp read_json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  # Fast client opts so the 5xx-retry path doesn't sleep the whole suite.
  defp fast, do: [max_retries: 1, retry_delay_ms: 5]

  defp reload(doc_id, scope) do
    {:ok, doc} = Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)
    doc
  end

  # ---------------------------------------------------------------------------
  # CREATE path
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — create" do
    test "creates the issue and stamps content.github with the issue number", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Mirror me", "description" => "do the thing"}, scope)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"number" => 42, "state" => "open"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      # The desired shape was POSTed, and the Task: trailer carries the
      # PUBLISHED id (never the drafts. prefix).
      body = Agent.get(body_ref, & &1)
      assert body["title"] == "Mirror me"
      assert body["body"] =~ "do the thing"
      assert body["body"] =~ "Task: #{id}"
      refute body["body"] =~ "drafts."

      # content.github is now anchored on issue 42, ready for idempotent PATCH.
      gh = Link.get(reload(id, scope))
      assert gh["repo"] == @repo
      assert gh["issue"] == 42
      assert gh["state"] == "synced"
      assert is_binary(gh["synced_rev"])
    end

    test "a task born closed (done) → create issue then PATCH it closed in one reconcile", %{
      bypass: bypass,
      scope: scope
    } do
      # A create+close coalesced into one reconcile: the ledger already wants the
      # task closed, but GitHub's create verb can only birth an OPEN issue. The
      # reconcile must record the number, then close it with a follow-up PATCH —
      # otherwise nothing re-enqueues (the stamp is source:github) and the issue
      # is stranded open.
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"lifecycle_status" => "done"}, scope)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 55, "state" => "open"}))
      end)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/55", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 55, "state" => "closed"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      body = Agent.get(body_ref, & &1)
      assert body["state"] == "closed"
      assert body["state_reason"] == "completed"

      gh = Link.get(reload(id, scope))
      assert gh["issue"] == 55
      assert gh["state"] == "synced"
      assert is_binary(gh["synced_rev"])
    end

    test "404 on create → {:cancel, :repo_not_found} (repo missing, nothing to detach)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)

      Bypass.stub(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:cancel, :repo_not_found} = MirrorJob.reconcile(id, @dataset, fast())
      # No issue was recorded.
      assert Link.get(reload(id, scope)) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # UPDATE path
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — update (open)" do
    test "PATCHes an already-mirrored open task in one idempotent call", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Ongoing", "lifecycle_status" => "in_progress"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 7, state: "synced"}, scope)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/7", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 7, "state" => "open"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      body = Agent.get(body_ref, & &1)
      assert body["state"] == "open"
      # An open task carries a nil state_reason — the key is DROPPED, not sent null.
      refute Map.has_key?(body, "state_reason")
      assert body["title"] == "Ongoing"

      gh = Link.get(reload(id, scope))
      assert gh["issue"] == 7
      assert is_binary(gh["synced_rev"])
    end
  end

  describe "reconcile/2 — update (close)" do
    test "done → closed/completed", %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"lifecycle_status" => "done"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 11, state: "synced"}, scope)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/11", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 11, "state" => "closed"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      body = Agent.get(body_ref, & &1)
      assert body["state"] == "closed"
      assert body["state_reason"] == "completed"
    end

    test "cancelled → closed/not_planned", %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"lifecycle_status" => "cancelled"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 12, state: "synced"}, scope)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/12", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 12, "state" => "closed"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      body = Agent.get(body_ref, & &1)
      assert body["state"] == "closed"
      assert body["state_reason"] == "not_planned"
    end
  end

  # ---------------------------------------------------------------------------
  # Error classification (contract #3, D8/D9)
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — error classification" do
    test "422 on update → {:cancel, {:client_error, 422}} (permanent dead-letter)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 8, state: "synced"}, scope)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/8", fn conn ->
        Plug.Conn.resp(conn, 422, ~s({"message":"Validation Failed"}))
      end)

      assert {:cancel, {:client_error, 422}} = MirrorJob.reconcile(id, @dataset, fast())
    end

    test "429 with Retry-After → {:snooze, retry_after}", %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 9, state: "synced"}, scope)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/9", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "42")
        |> Plug.Conn.resp(429, ~s({"message":"rate limited"}))
      end)

      assert {:snooze, 42} = MirrorJob.reconcile(id, @dataset, fast())
    end

    test "exhausted 5xx → {:error, NetworkError} (Oban retries)", %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 10, state: "synced"}, scope)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/10", fn conn ->
        Plug.Conn.resp(conn, 503, "{}")
      end)

      assert {:error, %Barkpark.Plugins.Github.Errors.NetworkError{reason: {:http, 503}}} =
               MirrorJob.reconcile(id, @dataset, fast())
    end

    test "404 on update → stamps state:detached and {:cancel, :detached} (never recreate)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 13, state: "synced"}, scope)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/13", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:cancel, :detached} = MirrorJob.reconcile(id, @dataset, fast())

      gh = Link.get(reload(id, scope))
      assert gh["state"] == "detached"
      # The issue number is preserved (merge), just marked detached.
      assert gh["issue"] == 13
    end
  end

  # ---------------------------------------------------------------------------
  # Short-circuits
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — short-circuits" do
    test "absent task → {:cancel, :task_gone}", %{scope: _scope} do
      assert {:cancel, :task_gone} = MirrorJob.reconcile(uniq("ghost"), @dataset, fast())
    end

    test "detached link → {:cancel, :detached}, no HTTP", %{bypass: bypass, scope: scope} do
      # No Bypass stub at all: any HTTP call would fail the test.
      Bypass.down(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 20, state: "detached"}, scope)

      assert {:cancel, :detached} = MirrorJob.reconcile(id, @dataset, fast())
    end

    test "no mirror repo configured → {:cancel, :repo_unconfigured}, no HTTP", %{
      bypass: bypass,
      scope: scope
    } do
      # An enabled-but-unconfigured plugin must dead-letter, not FunctionClause-
      # crash the client on a nil repo and let Oban retry the crash forever.
      Bypass.down(bypass)
      cfg = Application.get_env(:barkpark, Barkpark.Plugins.Github)
      Application.put_env(:barkpark, Barkpark.Plugins.Github, Keyword.delete(cfg, :repo))
      on_exit(fn -> Application.put_env(:barkpark, Barkpark.Plugins.Github, cfg) end)

      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)

      assert {:cancel, :repo_unconfigured} = MirrorJob.reconcile(id, @dataset, fast())
    end

    test "already-synced (synced_rev == _rev) → :ok, no HTTP", %{bypass: bypass, scope: scope} do
      Bypass.down(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 21, state: "synced"}, scope)

      # Force content.github.synced_rev == the row's current _rev WITHOUT bumping
      # the rev (a normal write can never do this — the stamp itself bumps _rev,
      # which is exactly why the no-op is dead in steady state, charter D3). This
      # proves the coalesce guard fires when it CAN.
      current = reload(id, scope)
      github = Link.get(current) |> Map.put("synced_rev", current.rev)
      content = Map.put(current.content, "github", github)
      {:ok, _} = current |> Ecto.Changeset.change(content: content) |> Repo.update()

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())
    end
  end

  # ---------------------------------------------------------------------------
  # Oban args wiring
  # ---------------------------------------------------------------------------

  describe "perform_job/2 smoke" do
    test "the {doc_id, dataset} args route through perform → reconcile", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Via Oban"}, scope)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 77}))
      end)

      assert :ok =
               perform_job(MirrorJob, %{"doc_id" => id, "dataset" => @dataset})

      assert Link.get(reload(id, scope))["issue"] == 77
    end
  end
end
