# ---------------------------------------------------------------------------
# Injected Projects/Relations seams (Wave-5 slices 2/3 are not in THIS worktree;
# slice 4 resolves them through a seam so it compiles + tests standalone). Each
# stub runs SYNCHRONOUSLY in the test process — `send(self(), …)` lands in the
# test mailbox — and delegates to an optional impl fun threaded through `opts`.
# ---------------------------------------------------------------------------
defmodule Barkpark.Plugins.Github.MirrorJobTest.ProjectsStub do
  @moduledoc false
  def sync(task, repo, num, link, opts) do
    send(self(), {:projects_called, num})

    case opts[:projects_impl] do
      fun when is_function(fun, 4) -> fun.(task, repo, num, link)
      _ -> :noop
    end
  end
end

defmodule Barkpark.Plugins.Github.MirrorJobTest.RelationsStub do
  @moduledoc false
  def hydrate_blocker_refs(task, dataset, opts) do
    case opts[:hydrate_impl] do
      fun when is_function(fun, 2) -> fun.(task, dataset)
      _ -> task
    end
  end

  def sync(task, repo, num, dataset, opts) do
    send(self(), {:relations_called, num})

    case opts[:relations_impl] do
      fun when is_function(fun, 4) -> fun.(task, repo, num, dataset)
      _ -> :noop
    end
  end
end

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
  alias Barkpark.Plugins.Github.{Auth, Conflicts, Link, MirrorJob}
  alias Barkpark.Plugins.Github.MirrorJobTest.{ProjectsStub, RelationsStub}

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

    # Auth is a boot-started singleton (register_workers/1); don't start a
    # second one — just reset its token cache so this test's creds take effect.
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

  # The pre-PATCH drift GET (charter D7). Every update-path reconcile reads the
  # issue's current state before it PATCHes, so an update test must stub it.
  # Defaults to a minimal open issue; pass a body to simulate a hand-edited issue.
  defp stub_get(bypass, num, body \\ nil) do
    resp = body || %{"number" => num, "state" => "open", "title" => "gh-#{num}"}

    Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/#{num}", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(resp))
    end)
  end

  # Fast client opts so the 5xx-retry path doesn't sleep the whole suite.
  defp fast, do: [max_retries: 1, retry_delay_ms: 5]

  # Wire the injected Projects/Relations seams (+ any per-test impl/enqueue funs).
  defp seams(extra \\ []) do
    fast() ++ [projects_mod: ProjectsStub, relations_mod: RelationsStub] ++ extra
  end

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

    test "repo resolves from the DB plugin_settings row, not just app env (live-instance regression)",
         %{bypass: bypass, scope: scope} do
      # A provisioned instance stores `repo` in the encrypted plugin_settings row,
      # NOT app env. Before the fix, reconcile read env-only `cfg()[:repo]` and
      # every drained job cancelled `:repo_unconfigured` despite the plugin being
      # active. Drop `repo` from env, put it in the DB, and assert the mirror still
      # creates the issue (i.e. resolves via Settings.repo/0's env→DB fallback).
      env = Application.get_env(:barkpark, Barkpark.Plugins.Github, [])
      Application.put_env(:barkpark, Barkpark.Plugins.Github, Keyword.delete(env, :repo))
      on_exit(fn -> Application.put_env(:barkpark, Barkpark.Plugins.Github, env) end)

      {:ok, _} = Barkpark.Plugins.Settings.put("github", %{"repo" => @repo})
      on_exit(fn -> Barkpark.Plugins.Settings.delete("github") end)

      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "DB-repo mirror"}, scope)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"number" => 77, "state" => "open"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())
      assert Link.get(reload(id, scope))["issue"] == 77
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

      # The born-closed follow-up PATCH runs through the update path, so it reads
      # the freshly created (open) issue first.
      stub_get(bypass, 55)

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
  # Tenant scope threading (wave-2.5 carry)
  # ---------------------------------------------------------------------------

  describe "reconcile/3 — tenant scope threading" do
    test "a task in a NON-default workspace is loaded + stamped under its OWN scope", %{
      bypass: bypass
    } do
      stub_token(bypass)

      # A task living in its own workspace/project, distinct from the default
      # scope the rest of the suite uses.
      ws = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(ws)
      tenant = [workspace_id: ws.id, project_id: project.id]
      register_schemas!(tenant)

      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Tenant task", "description" => "scoped"}, tenant)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 314, "state" => "open"}))
      end)

      # Scope is threaded reconcile → load_task + Link.put. WITHOUT the write
      # scope the stamp would land in the seeded DEFAULT workspace (writes resolve
      # nil→Default), so this ws-scoped read would see NO link — the exact pre-fix
      # "mis-written" gap. The assertion below therefore only passes when the
      # stamp lands under the task's own scope.
      assert :ok = MirrorJob.reconcile(id, @dataset, fast() ++ tenant)

      gh = Link.get(reload(id, tenant))
      assert gh["repo"] == @repo
      assert gh["issue"] == 314
      assert gh["state"] == "synced"
      assert is_binary(gh["synced_rev"])
    end

    test "the {workspace_id, project_id} Oban args route through perform → scoped reconcile",
         %{bypass: bypass} do
      stub_token(bypass)

      ws = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(ws)
      tenant = [workspace_id: ws.id, project_id: project.id]
      register_schemas!(tenant)

      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Via scoped Oban"}, tenant)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 271}))
      end)

      assert :ok =
               perform_job(MirrorJob, %{
                 "doc_id" => id,
                 "dataset" => @dataset,
                 "workspace_id" => ws.id,
                 "project_id" => project.id
               })

      assert Link.get(reload(id, tenant))["issue"] == 271
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

      stub_get(bypass, 7)

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
      # First update with no prior fingerprint stamps one for next-reconcile drift
      # detection (charter D7 — rolls forward without backfill).
      assert is_integer(gh["synced_fingerprint"])
      # No prior fingerprint existed, so this pass records nothing.
      assert Conflicts.list(kind: "out_of_band_edit") == []
    end
  end

  describe "reconcile/2 — update (close)" do
    test "done → closed/completed", %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"lifecycle_status" => "done"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 11, state: "synced"}, scope)

      stub_get(bypass, 11)

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

      stub_get(bypass, 12)

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

      stub_get(bypass, 8)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/8", fn conn ->
        Plug.Conn.resp(conn, 422, ~s({"message":"Validation Failed"}))
      end)

      assert {:cancel, {:client_error, 422}} = MirrorJob.reconcile(id, @dataset, fast())

      # The dead-letter is now VISIBLE (charter decision 3): a cancelled Oban job
      # is invisible outside oban_jobs.errors, so the 4xx is RECORDED before the
      # cancel — exactly ONE out_of_band_edit row (D14 reuses the kind), the
      # client_error discriminated on detail.source + detail.status.
      assert [conflict] = Conflicts.list(kind: "out_of_band_edit")
      assert conflict.repo == @repo
      assert conflict.issue == 8
      assert conflict.doc_id == id
      assert conflict.detail["source"] == "client_error"
      assert conflict.detail["status"] == 422
    end

    test "429 with Retry-After → {:snooze, retry_after}", %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 9, state: "synced"}, scope)

      stub_get(bypass, 9)

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

      stub_get(bypass, 10)

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

      # The drift GET succeeds; the PATCH is what discovers the issue is gone.
      stub_get(bypass, 13)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/13", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:cancel, :detached} = MirrorJob.reconcile(id, @dataset, fast())

      gh = Link.get(reload(id, scope))
      assert gh["state"] == "detached"
      # The issue number is preserved (merge), just marked detached.
      assert gh["issue"] == 13

      # The detach is now VISIBLE (D7) — a quarantine row was recorded.
      assert [conflict] = Conflicts.list(kind: "detached")
      assert conflict.repo == @repo
      assert conflict.issue == 13
      assert conflict.doc_id == id
      assert conflict.detail["reason"] =~ "deleted or transferred"
    end
  end

  # ---------------------------------------------------------------------------
  # Conflict quarantine (D7 — record out-of-band drift before converging)
  # ---------------------------------------------------------------------------

  describe "reconcile/2 — conflict quarantine (D7)" do
    test "an issue drifted out-of-band since our last write → records before it PATCHes", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Ledger title"}, scope)

      # A stored fingerprint from a prior write. The sentinel is deliberately
      # OUTSIDE phash2's 0..2^27-1 range, so the observed fingerprint can NEVER
      # equal it — the drift branch is guaranteed to fire.
      {:ok, _} =
        Link.put(
          id,
          @dataset,
          %{repo: @repo, issue: 30, state: "synced", synced_fingerprint: 9_999_999_999},
          scope
        )

      # The issue as a human left it — a hand-edited title + an extra label.
      stub_get(bypass, 30, %{
        "number" => 30,
        "state" => "open",
        "title" => "Hand-edited by a human",
        "labels" => [%{"name" => "wontfix"}]
      })

      {:ok, patched?} = Agent.start_link(fn -> false end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/30", fn conn ->
        Agent.update(patched?, fn _ -> true end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 30, "state" => "open"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      # Ledger still wins — the PATCH fired AFTER the record.
      assert Agent.get(patched?, & &1) == true

      # The drift is now VISIBLE: one open out_of_band_edit conflict, carrying the
      # observed GitHub field values + the observed fingerprint (D7). The GET read
      # those values ONLY to fingerprint the record — never into a task (D5).
      assert [conflict] = Conflicts.list(kind: "out_of_band_edit")
      assert conflict.repo == @repo
      assert conflict.issue == 30
      assert conflict.doc_id == id
      assert conflict.detail["github_fields"]["title"] == "Hand-edited by a human"
      assert conflict.detail["github_fields"]["state"] == "open"
      assert conflict.detail["github_fields"]["labels"] == ["wontfix"]
      assert is_integer(conflict.detail["observed_fp"])

      # A fresh fingerprint of the DESIRED shape is stamped for next time.
      assert is_integer(Link.get(reload(id, scope))["synced_fingerprint"])
    end

    test "an issue matching the stored fingerprint → NO conflict recorded", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Steady", "description" => "unchanged"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 31, state: "synced"}, scope)

      # The GET reflects back exactly what we last PATCHed. We can't compute the
      # projected body by hand, so capture the first PATCH body and feed it to the
      # GET on the SECOND reconcile — a faithful GitHub echo of our own write.
      {:ok, echo} = Agent.start_link(fn -> %{"number" => 31, "state" => "open"} end)

      Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/31", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(Agent.get(echo, & &1)))
      end)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/31", fn conn ->
        {json, conn} = read_json_body(conn)
        # Mimic GitHub FAITHFULLY: it re-encodes a stored issue body's newlines to
        # CRLF and echoes them back on read. The steady-state fingerprint MUST see
        # through this, else every reconcile of a multi-line body records a
        # spurious out_of_band_edit. Without body-newline normalization in the
        # fingerprint, this line makes the second-pass assertion below fail.
        github_echo = Map.update(json, "body", nil, &String.replace(&1, "\n", "\r\n"))
        Agent.update(echo, fn _ -> github_echo end)
        Plug.Conn.resp(conn, 200, Jason.encode!(github_echo))
      end)

      # First pass: no stored fingerprint yet → records nothing, stamps the fp and
      # (via the PATCH stub) makes the echo equal to what we wrote.
      assert :ok = MirrorJob.reconcile(id, @dataset, fast())
      # Second pass: the GET now echoes our own last write → fingerprints match →
      # no drift recorded.
      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      assert Conflicts.list(kind: "out_of_band_edit") == []
    end

    test "GET 404 (issue vanished between drain and reconcile) → detached, never recreated", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 32, state: "synced"}, scope)

      # The drift GET itself 404s. No PATCH stub at all — if a PATCH (recreate/
      # write) were attempted, Bypass would fail the test.
      Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/32", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:cancel, :detached} = MirrorJob.reconcile(id, @dataset, fast())

      gh = Link.get(reload(id, scope))
      assert gh["state"] == "detached"
      assert gh["issue"] == 32

      assert [conflict] = Conflicts.list(kind: "detached")
      assert conflict.issue == 32
      assert conflict.doc_id == id
    end

    test "first-ever update (no stored fingerprint) → records nothing, stamps a fingerprint", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Fresh"}, scope)
      # Linked but never fingerprinted (a pre-slice task, or a born-open create).
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 33, state: "synced"}, scope)
      refute Link.get(reload(id, scope))["synced_fingerprint"]

      stub_get(bypass, 33, %{"number" => 33, "state" => "open", "title" => "anything at all"})

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/33", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 33, "state" => "open"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      # Nothing to compare against yet → no conflict, but the fingerprint is now
      # stamped so the NEXT reconcile can detect drift (rolls forward, no backfill).
      assert Conflicts.list(kind: "out_of_band_edit") == []
      assert is_integer(Link.get(reload(id, scope))["synced_fingerprint"])
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

      # Detached is NEVER advanced to synced (task-eb5ac970477f9308 guard): the
      # link short-circuits before converge, so no PATCH and no state stamp ever
      # touches it — the state stays exactly "detached".
      assert Link.get(reload(id, scope))["state"] == "detached"
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

    test "intake link + pre-adoption edit → {:cancel, :intake}, no HTTP (D13 gate)", %{
      bypass: bypass,
      scope: scope
    } do
      # A born-dark inbound issue awaiting adoption: it carries the outsider's issue
      # number but NO synced_rev, so `synced?` is false and an ordinary Barkpark edit
      # would otherwise converge and PATCH the outsider's still-owned issue with our
      # projection BEFORE consent. Any HTTP call fails the test — the gate must fire
      # before the client resolves a token.
      Bypass.down(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "edited before adopt"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 22, state: "intake"}, scope)
      # Prove the coalesce guard can't be what fires: an intake link has no synced_rev.
      refute Link.get(reload(id, scope))["synced_rev"]

      assert {:cancel, :intake} = MirrorJob.reconcile(id, @dataset, fast())
    end

    test "adopted link with NO synced_rev still converges + advances state to synced (intake→adopt→edit→mirror)",
         %{bypass: bypass, scope: scope} do
      # PROTECTIVE twin of the intake gate: `adopted` also lacks a synced_rev until its
      # first mirror. The gate keys on the STATE STRING, never synced_rev absence, so
      # the consent-moment first push MUST fire GET + PATCH and stamp synced_rev +
      # fingerprint. Keying on synced_rev absence would strand every just-adopted task.
      #
      # It ALSO advances github.state adopted→synced (task-eb5ac970477f9308): the born
      # create path stamps `synced` in after_create, but an intake→adopt task first
      # reaches `synced` only through THIS update PATCH. Before the fix patch/9 stamped
      # only synced_rev/synced_fingerprint and the state field lied `adopted` forever.
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "just adopted"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 23, state: "adopted"}, scope)
      refute Link.get(reload(id, scope))["synced_rev"]
      assert Link.get(reload(id, scope))["state"] == "adopted"

      stub_get(bypass, 23)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/23", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 23, "state" => "open"}))
      end)

      assert :ok = MirrorJob.reconcile(id, @dataset, fast())

      gh = Link.get(reload(id, scope))
      assert is_binary(gh["synced_rev"])
      assert is_integer(gh["synced_fingerprint"])
      # The state field no longer lies: the first mirror advanced adopted→synced.
      assert gh["state"] == "synced"
      # The issue number survives the merge.
      assert gh["issue"] == 23
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

    test "enqueue normalizes a drafts. doc_id → published form so create/publish coalesce" do
      # The draft-create event carries `drafts.X`; the publish event carries `X`.
      # Both must enqueue the SAME unique job or the mirror creates a DUPLICATE
      # issue. build_args normalizes to the published id; Oban's unique clause
      # (keyed on doc_id) then collapses the second insert.
      {:ok, j1} = MirrorJob.enqueue(%{doc_id: "drafts.gh-dedup", dataset: @dataset})
      assert j1.args["doc_id"] == "gh-dedup"

      {:ok, j2} = MirrorJob.enqueue(%{doc_id: "gh-dedup", dataset: @dataset})
      assert j2.args["doc_id"] == "gh-dedup"
      # Same unique job (the publish insert is a no-op that returns the draft's job).
      assert j2.id == j1.id
    end
  end

  # ---------------------------------------------------------------------------
  # Projections + relations wiring (Wave 5 slice 4) — Projects v2 + sub-issues,
  # each FAILURE-ISOLATED behind the issue mirror (D10/D11/D9).
  # ---------------------------------------------------------------------------

  describe "reconcile/3 — projections wiring (slice 4)" do
    test "(a) a normal create still mirrors the issue + stamps synced_rev while Projects :noop",
         %{
           bypass: bypass,
           scope: scope
         } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Isolated"}, scope)

      Bypass.expect_once(bypass, "POST", "/repos/#{@repo}/issues", fn conn ->
        Plug.Conn.resp(conn, 201, Jason.encode!(%{"number" => 42, "state" => "open"}))
      end)

      # No projects_impl → the stub returns :noop (the blank-project_id posture):
      # the issue loop is 100% unaffected and NOTHING is stamped for projects.
      assert :ok = MirrorJob.reconcile(id, @dataset, seams())

      gh = Link.get(reload(id, scope))
      assert gh["issue"] == 42
      assert is_binary(gh["synced_rev"])
      refute gh["projects_fingerprint"]

      # Both projections ran AFTER the issue existed (they carry the issue number).
      assert_received {:projects_called, 42}
      assert_received {:relations_called, 42}
    end

    test "(b) a Projects error is SWALLOWED — the issue is still PATCHed + synced_rev stamped", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Flagship isolation"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 50, state: "synced"}, scope)

      stub_get(bypass, 50)

      {:ok, patched?} = Agent.start_link(fn -> false end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/50", fn conn ->
        Agent.update(patched?, fn _ -> true end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 50, "state" => "open"}))
      end)

      # Projects blows up (simulating a GraphQL 500) — the reconcile MUST still
      # return :ok and the issue must still be mirrored (the flagship safety prop).
      boom = fn _task, _repo, _num, _link -> {:error, :graphql_boom} end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(projects_impl: boom))

      assert Agent.get(patched?, & &1) == true
      gh = Link.get(reload(id, scope))
      assert is_binary(gh["synced_rev"])
      assert is_integer(gh["synced_fingerprint"])
      refute gh["projects_fingerprint"]
    end

    test "(b'') a Projects RAISE is caught by isolate/3 — the issue is still mirrored", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Crash isolation"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 52, state: "synced"}, scope)

      stub_get(bypass, 52)

      {:ok, patched?} = Agent.start_link(fn -> false end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/52", fn conn ->
        Agent.update(patched?, fn _ -> true end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 52, "state" => "open"}))
      end)

      # Projects RAISES (a bug in the eventual Projects module, an exhausted GraphQL
      # decode, etc.) rather than returning {:error, _}. `isolate/3` MUST rescue it,
      # log, and downgrade to :ok — the proven Issues loop is 100% unaffected. This
      # is the flagship failure-isolation invariant via the rescue path (test (b)
      # only exercises the returned-{:error} swallow path).
      crash = fn _task, _repo, _num, _link -> raise "projects module exploded" end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(projects_impl: crash))

      # Issue still PATCHed + stamped despite the projection crash.
      assert Agent.get(patched?, & &1) == true
      gh = Link.get(reload(id, scope))
      assert is_binary(gh["synced_rev"])
      assert is_integer(gh["synced_fingerprint"])
      refute gh["projects_fingerprint"]

      # Relations STILL ran after the isolated Projects crash (the crash is
      # confined to the Projects sub-step, not the whole projections pass).
      assert_received {:relations_called, 52}
    end

    test "(b') a Projects rate-limit MAY snooze the whole reconcile (D9)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Snooze me"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 51, state: "synced"}, scope)

      stub_get(bypass, 51)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/51", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 51, "state" => "open"}))
      end)

      rate = fn _task, _repo, _num, _link ->
        {:error, %Barkpark.Plugins.Github.Errors.RateLimitError{retry_after: 17}}
      end

      # The issue PATCH already ran (idempotent); the snooze re-runs it later.
      assert {:snooze, 17} = MirrorJob.reconcile(id, @dataset, seams(projects_impl: rate))
    end

    test "(c) relations sync runs AFTER the issue exists (mirrored parent → sub-issue link)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Child", "parent_id" => "gh-parent"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 60, state: "synced"}, scope)

      stub_get(bypass, 60)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/60", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 60, "state" => "open"}))
      end)

      # Simulate Relations linking the child under its mirrored parent — the
      # issue number is only knowable because the issue already exists.
      link_it = fn _task, _repo, num, _dataset ->
        send(self(), {:sub_issue_linked, num})
        :ok
      end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(relations_impl: link_it))
      assert_received {:sub_issue_linked, 60}
    end

    test "(d) an UNMIRRORED parent defers: enqueues the parent + a bounded relink child", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Orphan child", "parent_id" => "gh-parent"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 70, state: "synced"}, scope)

      stub_get(bypass, 70)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/70", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 70, "state" => "open"}))
      end)

      defer = fn _task, _repo, _num, _dataset -> {:defer, :parent_unmirrored} end
      enq = fn payload -> send(self(), {:enqueued, payload}) end

      assert :ok =
               MirrorJob.reconcile(id, @dataset, seams(relations_impl: defer, enqueue_fun: enq))

      # The PARENT's mirror is enqueued NOW (default 30s debounce, no relink)…
      assert_received {:enqueued, %{fields: %{doc_id: "gh-parent"}, schedule_in: 30}}
      # …and THIS child re-enqueues as a bounded relink job (attempt 1, 60s out).
      assert_received {:enqueued,
                       %{
                         fields: %{doc_id: ^id, relink: true, relink_attempt: 1},
                         schedule_in: 60
                       }}
    end

    test "(d') at the relink cap the defer cap-flattens to a parent_marker (no relink loop)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Deep child", "parent_id" => "gh-parent"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 71, state: "synced"}, scope)

      stub_get(bypass, 71)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/71", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 71, "state" => "open"}))
      end)

      defer = fn _task, _repo, _num, _dataset -> {:defer, :parent_unmirrored} end
      enq = fn payload -> send(self(), {:enqueued, payload}) end

      # relink_attempt already at the cap → the deferred child cap-flattens: it
      # stamps a parent_marker link key (never a native sub-issue) and re-enqueues
      # ONCE more (attempt pinned at the cap, so it can never loop).
      assert :ok =
               MirrorJob.reconcile(
                 id,
                 @dataset,
                 seams(relations_impl: defer, enqueue_fun: enq, relink: true, relink_attempt: 3)
               )

      assert Link.get(reload(id, scope))["parent_marker"] == "gh-parent"
      assert_received {:enqueued, %{fields: %{relink: true, relink_attempt: 3}, schedule_in: 60}}
      # NOT a fresh attempt-0 cycle and NOT a parent enqueue at the cap.
      refute_received {:enqueued, %{fields: %{doc_id: "gh-parent"}}}
    end

    test "(e) hydrated blocker_issue_refs land in the PATCH body as a blocks marker", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Blocked task", "description" => "human brief"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 80, state: "synced"}, scope)

      stub_get(bypass, 80)

      {:ok, body_ref} = Agent.start_link(fn -> nil end)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/80", fn conn ->
        {json, conn} = read_json_body(conn)
        Agent.update(body_ref, fn _ -> json end)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 80, "state" => "open"}))
      end)

      hyd = fn task, _dataset -> Map.put(task, "blocker_issue_refs", [99]) end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(hydrate_impl: hyd))

      body = Agent.get(body_ref, & &1)
      assert body["body"] =~ "<!-- barkpark:blocks:start -->"
      assert body["body"] =~ "Blocked by: #99"
    end

    test "(f) an UNCHANGED task on a second reconcile writes ZERO GraphQL (fingerprint :noop)", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Steady projection"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 90, state: "synced"}, scope)

      # Two reconciles fire GET + PATCH twice, so use stubs (not expect_once).
      Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/90", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 90, "state" => "open"}))
      end)

      Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/90", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 90, "state" => "open"}))
      end)

      # Faithful Projects diff: fingerprint the task, compare to the stored
      # projects_fingerprint off the link; equal → :noop (ZERO GraphQL), else emit
      # one GraphQL "write" and return the fp to stamp. Proves the WIRING stamps
      # projects_fingerprint so the next pass sees it and no-ops (D10).
      diff = fn task, _repo, _num, link ->
        fp = :erlang.phash2(Map.get(task.content, "title"))
        stored = is_map(link) && Map.get(link, "projects_fingerprint")

        if stored == fp do
          :noop
        else
          send(self(), {:graphql_write, fp})
          {:ok, %{fingerprint: fp, item_id: "PVTI_stub"}}
        end
      end

      # First pass: no stored fingerprint → one GraphQL write, fingerprint stamped.
      assert :ok = MirrorJob.reconcile(id, @dataset, seams(projects_impl: diff))
      assert_received {:graphql_write, _fp}
      assert is_integer(Link.get(reload(id, scope))["projects_fingerprint"])

      # Second pass: the stored fingerprint now equals the desired one → :noop,
      # ZERO GraphQL. The task never changed, so Projects writes nothing.
      assert :ok = MirrorJob.reconcile(id, @dataset, seams(projects_impl: diff))
      refute_received {:graphql_write, _fp2}
    end

    test "(g) relink bypasses the synced short-circuit so a SYNCED child still re-links", %{
      bypass: bypass,
      scope: scope
    } do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Synced child", "parent_id" => "gh-parent"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 95, state: "synced"}, scope)

      # Force synced_rev == current _rev so the ordinary reconcile would short out.
      current = reload(id, scope)
      github = Link.get(current) |> Map.put("synced_rev", current.rev)
      content = Map.put(current.content, "github", github)
      {:ok, _} = current |> Ecto.Changeset.change(content: content) |> Repo.update()

      # Without relink this is a pure no-op (any HTTP would fail the test).
      assert :ok = MirrorJob.reconcile(id, @dataset, seams())
      refute_received {:relations_called, _}

      # WITH relink the reconcile runs, re-PATCHes idempotently, and relations fire.
      stub_get(bypass, 95)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/95", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 95, "state" => "open"}))
      end)

      link_it = fn _task, _repo, num, _dataset ->
        send(self(), {:relinked, num})
        :ok
      end

      assert :ok =
               MirrorJob.reconcile(
                 id,
                 @dataset,
                 seams(relations_impl: link_it, relink: true, relink_attempt: 1)
               )

      assert_received {:relinked, 95}
    end

    test "(h) a Projects GraphQL rate-limit is RECORDED as a conflict, not swallowed silently",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "GraphQL rate-limited"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 53, state: "synced"}, scope)

      stub_get(bypass, 53)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/53", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 53, "state" => "open"}))
      end)

      # A GraphQL rate-limit is a 200-body error array, NOT a %RateLimitError{} —
      # Client.graphql/3 surfaces it as %NetworkError{reason: {:graphql, errors}}.
      # Before this slice it fell to the bare Logger.warning and VANISHED. Now it
      # is recorded as an out_of_band_edit conflict (source: "graphql") and the
      # reconcile still returns :ok (failure isolation intact).
      gql_rate = fn _task, _repo, _num, _link ->
        {:error,
         %Barkpark.Plugins.Github.Errors.NetworkError{
           reason:
             {:graphql, [%{"type" => "RATE_LIMITED", "message" => "API rate limit exceeded"}]}
         }}
      end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(projects_impl: gql_rate))

      # The issue itself still mirrored (isolation).
      gh = Link.get(reload(id, scope))
      assert is_binary(gh["synced_rev"])

      # …and the GraphQL rate-limit is now VISIBLE as a quarantine row.
      assert [conflict] = Conflicts.list(kind: "out_of_band_edit")
      assert conflict.issue == 53
      assert conflict.doc_id == id
      assert conflict.detail["source"] == "graphql"
      assert [%{"type" => "RATE_LIMITED"}] = conflict.detail["errors"]
    end

    test "(i) a REAL sub-issue rejection from Relations is RECORDED, then swallowed",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Reject child", "parent_id" => "gh-parent"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 54, state: "synced"}, scope)

      stub_get(bypass, 54)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/54", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 54, "state" => "open"}))
      end)

      # A real 422 rejection (NOT "already linked") bubbles from Relations as a
      # distinct {:sub_issue_rejected, …}. The wiring RECORDS it before swallowing
      # so the failed tree link is visible; the issue mirror still returns :ok.
      reject = fn _task, _repo, _num, _dataset ->
        {:error, {:sub_issue_rejected, 99, 12_345, "Issue may not be a sub-issue of itself"}}
      end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(relations_impl: reject))

      gh = Link.get(reload(id, scope))
      assert is_binary(gh["synced_rev"])

      assert [conflict] = Conflicts.list(kind: "out_of_band_edit")
      assert conflict.issue == 54
      assert conflict.doc_id == id
      assert conflict.detail["source"] == "sub_issue_rejected"
      assert conflict.detail["parent_issue"] == 99
      assert conflict.detail["child_db_id"] == 12_345
      assert conflict.detail["detail"] =~ "may not be a sub-issue"
    end

    test "(j) a non-rate GraphQL/atom projection error is still swallowed WITHOUT a conflict",
         %{bypass: bypass, scope: scope} do
      # A plain {:error, atom} projection failure (not a GraphQL NetworkError, not
      # a rate-limit, not a sub-issue rejection) stays a log-and-continue — no
      # quarantine row, exactly as before. Guards against over-recording.
      stub_token(bypass)
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Plain boom"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 56, state: "synced"}, scope)

      stub_get(bypass, 56)

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/56", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 56, "state" => "open"}))
      end)

      boom = fn _task, _repo, _num, _link -> {:error, :graphql_boom} end

      assert :ok = MirrorJob.reconcile(id, @dataset, seams(projects_impl: boom))
      assert Conflicts.list(kind: "out_of_band_edit") == []
    end
  end
end
