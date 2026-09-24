defmodule Barkpark.Plugins.Github.DeleteRetireTest do
  @moduledoc """
  THE DELETE ORPHAN (spd-b45-deleted-task-orphans-github-mirror).

  `MirrorJob`'s publish gate already closes the mirror when a published task is
  UNPUBLISHED (`{:cancel, :unpublished_closed}`). HARD DELETE was the arm it
  could not reach: `Lifecycle.delete_document/4` removes both the published and
  the draft row, so the next reconcile's `load_task/3` returns `nil` and the job
  cancels `:task_gone` — with the issue number it would have needed gone with
  the document. The issue stays OPEN forever, its body naming a task id that
  returns not_found. Five such orphans were found and closed by hand
  (#2355 #2356 #2357 #2358 #2516).

  The remedy is an `after_delete` lifecycle hook on the Github plugin: it reads
  `content.github` off the about-to-be-deleted document — the ONLY moment the
  issue number is still knowable — and enqueues a `RetireJob` that closes the
  issue `not_planned`, the same retraction the unpublish arm performs.

  These tests exercise the LIFECYCLE path end to end (delete → hook → Oban job
  → GitHub PATCH), never the hook function in isolation, because the finding
  was that the delete path had no hook at all.
  """

  # async: false — Auth is a singleton GenServer and we mutate Application env.
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.Lifecycle
  alias Barkpark.Plugins.Github.{Auth, Link, RetireJob}

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

    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    prior = Application.get_env(:barkpark, Barkpark.Plugins.Github)
    prior_plugins = Barkpark.PluginEnv.capture()

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

    # The hook only fires for a LOADED plugin. `DataCase.reset_plugins_env/0`
    # unsets `:plugins` before every test, so name the plugin explicitly rather
    # than depend on the Registry snapshot's contents.
    Barkpark.PluginEnv.put!([Barkpark.Plugins.Github])

    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.Github, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Github)
      end

      Barkpark.PluginEnv.restore(prior_plugins)
    end)

    {:ok, bypass: bypass, scope: scope}
  end

  # ---------------------------------------------------------------------------
  # Fixtures (mirrored from mirror_job_test.exs — same schemas, same walls)
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
    {:ok, _draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => Map.get(content, "title", doc_id),
          "content" =>
            LabelFixtures.with_registered_labels(
              Map.merge(
                %{
                  "kind" => "task",
                  "brief" => Barkpark.TaskBriefFixtures.brief(),
                  "lifecycle_status" => "open"
                },
                content
              ),
              @dataset
            )
        },
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, "task", @dataset, scope)
    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp stub_token(bypass) do
    Bypass.stub(bypass, "POST", @token_path, fn conn ->
      Plug.Conn.resp(conn, 201, Jason.encode!(%{"token" => @inst_token, "expires_in" => 3600}))
    end)
  end

  # Record every PATCH the mirror sends to `num`, so a test can assert on the
  # body AND on the absence of a call. Returns an Agent holding the call list
  # (newest last).
  defp record_patches(bypass, num) do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    Bypass.stub(bypass, "PATCH", "/repos/#{@repo}/issues/#{num}", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(calls, &(&1 ++ [Jason.decode!(body)]))
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => num, "state" => "closed"}))
    end)

    calls
  end

  defp patches(calls), do: Agent.get(calls, & &1)

  # Run whatever the delete enqueued. `testing: :manual` means nothing runs by
  # itself, so the drain is the step that turns an enqueued intent into a real
  # GitHub call — and its count is itself evidence (0 drained = no hook fired).
  defp drain, do: Oban.drain_queue(queue: :github_mirror, with_safety: false)

  # ---------------------------------------------------------------------------
  # THE HEADLINE
  # ---------------------------------------------------------------------------

  describe "delete_document/4 — mirror retirement" do
    test "deleting a published, MIRRORED task closes its issue instead of orphaning it",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      num = 2355

      _task = mk_task!(id, %{"title" => "Published, mirrored, then hard-deleted"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: num, state: "synced"}, scope)

      # PRECONDITIONS — assert the setup, not its exit code. The task must be
      # published AND carry a live issue number, or the test measures nothing.
      assert {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert Link.get(published)["issue"] == num

      calls = record_patches(bypass, num)

      assert {:ok, _} = Lifecycle.delete_document(id, "task", @dataset, scope)

      # The row really is gone — the orphan's defining property.
      assert {:error, _} = Content.get_document(id, "task", @dataset, scope)

      assert {:error, _} =
               Content.get_document(Content.draft_id(id), "task", @dataset, scope)

      drained = drain()

      assert length(patches(calls)) == 1,
             "issue ##{num} was ORPHANED: the delete sent #{length(patches(calls))} " <>
               "PATCHes (drain: #{inspect(drained)})"

      [patch] = patches(calls)
      assert patch["state"] == "closed"
      assert patch["state_reason"] == "not_planned"
    end

    test "CONTROL: deleting a task that was NEVER mirrored makes no GitHub call",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")

      _task = mk_task!(id, %{"title" => "Never mirrored"}, scope)
      assert {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert Link.get(published) in [nil, %{}]

      calls = record_patches(bypass, 9999)

      assert {:ok, _} = Lifecycle.delete_document(id, "task", @dataset, scope)
      _ = drain()

      assert patches(calls) == []
    end

    test "CONTROL: a DETACHED link is never PATCHed — the issue is already gone (D7)",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      num = 4041

      _task = mk_task!(id, %{"title" => "Detached"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: num, state: "detached"}, scope)

      calls = record_patches(bypass, num)

      assert {:ok, _} = Lifecycle.delete_document(id, "task", @dataset, scope)
      _ = drain()

      assert patches(calls) == [],
             "a detached link's issue must never be touched, got #{inspect(patches(calls))}"
    end

    test "CONTROL: an INTAKE (un-adopted) link's outsider issue is never closed (D13)",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      num = 5051

      _task = mk_task!(id, %{"title" => "Born dark, never adopted"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: num, state: "intake"}, scope)

      calls = record_patches(bypass, num)

      assert {:ok, _} = Lifecycle.delete_document(id, "task", @dataset, scope)
      _ = drain()

      assert patches(calls) == [],
             "a pre-adoption intake issue belongs to the outsider, got #{inspect(patches(calls))}"
    end

    test "the enqueued job carries the issue number and the task's tenant scope",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      num = 7070

      _task = mk_task!(id, %{"title" => "Scope carried"}, scope)
      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: num, state: "synced"}, scope)

      assert {:ok, _} = Lifecycle.delete_document(id, "task", @dataset, scope)

      assert_enqueued(
        worker: RetireJob,
        args: %{
          doc_id: id,
          dataset: @dataset,
          repo: @repo,
          issue: num,
          workspace_id: scope[:workspace_id],
          project_id: scope[:project_id]
        }
      )
    end

    test "CONTROL: the job REFUSES to close when the task id came back", %{
      bypass: bypass,
      scope: scope
    } do
      # The job exists to retire an issue whose task is GONE. "Gone" is a
      # property of the present: a delete-then-recreate inside the queue's
      # latency must not close a LIVE task's issue.
      stub_token(bypass)
      id = uniq("gh")
      num = 8080

      _task = mk_task!(id, %{"title" => "Deleted, then reborn"}, scope)
      calls = record_patches(bypass, num)

      args = %{
        "doc_id" => id,
        "dataset" => @dataset,
        "repo" => @repo,
        "issue" => num,
        "workspace_id" => scope[:workspace_id],
        "project_id" => scope[:project_id]
      }

      assert {:ok, _} = Content.get_document(id, "task", @dataset, scope)
      assert {:cancel, :task_returned} = perform_job(RetireJob, args)
      assert patches(calls) == []
    end
  end
end
