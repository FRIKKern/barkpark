defmodule Barkpark.Plugins.Github.RestripTest do
  @moduledoc """
  Owner ruling #11 (2026-10-03): every issue mirrored before the body strip is
  rewritten to the stripped body.

  `Restrip.plan/2` counts what would change without calling GitHub;
  `Restrip.enqueue/2` inserts one spaced `RestripJob` per changed issue; a
  restrip reconcile re-PATCHes an ALREADY-SYNCED task (the ordinary mirror
  short-circuits it) with the stripped body.
  """
  use Barkpark.DataCase, async: false

  # The github plugin starts Plugins.Github.Auth.
  @moduletag :requires_plugins
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Content, LabelFixtures, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Github.{Auth, Link, MirrorJob, Restrip, RestripJob}

  @dataset "production"
  @repo "FRIKKern/barkpark"
  @installation_id "987654"
  @internal "Fix api/lib/barkpark/auth.ex:412, found by worker fable-7."

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # Unique per call: the task dedup gate refuses near-identical births.
  defp internal_brief, do: "#{@internal} Ref zr#{System.unique_integer([:positive])}q."

  defp mirrored!(doc_id, content, scope, link) do
    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
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

    {:ok, _} = Content.publish_document(doc_id, "task", @dataset, scope)

    if link, do: {:ok, _} = Link.put(doc_id, @dataset, link, scope)
    doc_id
  end

  defp link(n, state \\ "synced"), do: %{repo: @repo, issue: n, state: state}

  test "plan/2 counts mirrored, changed, allow-listed; skips unlinked, detached and intake rows",
       %{scope: scope} do
    internal = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(1))

    _public =
      mirrored!(
        uniq("t"),
        %{"description" => "A public roadmap item anyone may read.", "labels" => ["public"]},
        scope,
        link(2)
      )

    _intake =
      mirrored!("gh-#{System.unique_integer([:positive])}", %{}, scope, link(3, "adopted"))

    _unlinked = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, nil)

    _detached =
      mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(5, "detached"))

    _held = mirrored!("gh-#{System.unique_integer([:positive])}", %{}, scope, link(6, "intake"))

    plan = Restrip.plan(@dataset, scope)

    assert plan.mirrored == 3
    assert plan.would_change == 1
    assert plan.allowlisted == 2
    assert plan.changed_ids == [internal]
    refute plan.truncated
  end

  test "enqueue/2 inserts one spaced RestripJob per changed issue and nothing else",
       %{scope: scope} do
    a = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(10))
    b = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(11))
    _public = mirrored!(uniq("t"), %{"labels" => ["public"]}, scope, link(12))

    assert {:ok, 2} = Restrip.enqueue(@dataset, scope ++ [interval_seconds: 5])

    jobs = all_enqueued(worker: RestripJob)
    assert jobs |> Enum.map(& &1.args["doc_id"]) |> Enum.sort() == Enum.sort([a, b])
    [first, second] = Enum.sort_by(jobs, & &1.scheduled_at, DateTime)
    assert DateTime.diff(second.scheduled_at, first.scheduled_at) in 4..6
  end

  test "a second enqueue/2 skips tasks whose restrip job is still waiting", %{scope: scope} do
    a = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(13))
    assert {:ok, 1} = Restrip.enqueue(@dataset, scope)

    # The one-shot path writes job rows straight to oban_jobs, past Oban's
    # uniqueness check; a re-run must still not queue the same issue twice.
    b = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(14))
    assert {:ok, 1} = Restrip.enqueue(@dataset, scope)

    assert all_enqueued(worker: RestripJob) |> Enum.map(& &1.args["doc_id"]) |> Enum.sort() ==
             Enum.sort([a, b])
  end

  test "plan/2 counts an issue the mirror already wrote under the strip as stripped",
       %{scope: scope} do
    done = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(15))
    left = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(16))
    {:ok, _} = Link.put(done, @dataset, %{stripped: true}, scope)

    plan = Restrip.plan(@dataset, scope)

    assert plan.mirrored == 2
    assert plan.would_change == 1
    assert plan.stripped == 1
    assert plan.changed_ids == [left]
  end

  describe "a restrip reconcile" do
    setup do
      bypass = Bypass.open()
      base = "http://localhost:#{bypass.port}"
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
      prior = Application.get_env(:barkpark, Barkpark.Plugins.Github)

      Application.put_env(:barkpark, Barkpark.Plugins.Github,
        app_id: "123456",
        installation_id: @installation_id,
        private_key: pem,
        repo: @repo,
        api_base: base,
        github_api_base: base
      )

      Auth.invalidate()

      on_exit(fn ->
        if prior,
          do: Application.put_env(:barkpark, Barkpark.Plugins.Github, prior),
          else: Application.delete_env(:barkpark, Barkpark.Plugins.Github)
      end)

      Bypass.stub(
        bypass,
        "POST",
        "/app/installations/#{@installation_id}/access_tokens",
        fn conn ->
          Plug.Conn.resp(conn, 201, Jason.encode!(%{"token" => "ghs_x", "expires_in" => 3600}))
        end
      )

      %{bypass: bypass}
    end

    # Pin content.github.synced_rev to the row's rev without bumping it, so the
    # ordinary mirror's coalesce guard fires (as it does for a dormant task).
    defp force_synced!(doc_id, scope) do
      {:ok, current} = Content.get_document(doc_id, "task", @dataset, scope)
      github = Link.get(current) |> Map.put("synced_rev", current.rev)
      content = Map.put(current.content, "github", github)
      {:ok, _} = current |> Ecto.Changeset.change(content: content) |> Repo.update()
    end

    test "re-PATCHes an already-synced issue with the stripped body", %{
      bypass: bypass,
      scope: scope
    } do
      id = mirrored!(uniq("t"), %{"description" => internal_brief()}, scope, link(40))
      force_synced!(id, scope)

      # The ordinary mirror sees nothing to do (no HTTP at all).
      assert :ok = MirrorJob.reconcile(id, @dataset, max_retries: 1, retry_delay_ms: 5)

      Bypass.stub(bypass, "GET", "/repos/#{@repo}/issues/40", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{"number" => 40, "state" => "open", "title" => id})
        )
      end)

      test_pid = self()

      Bypass.expect_once(bypass, "PATCH", "/repos/#{@repo}/issues/40", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:patched, Jason.decode!(body)})
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 40}))
      end)

      assert :ok =
               MirrorJob.reconcile(id, @dataset,
                 restrip: true,
                 max_retries: 1,
                 retry_delay_ms: 5,
                 projects_mod: Barkpark.Plugins.Github.RestripTest.NoProjects,
                 relations_mod: Barkpark.Plugins.Github.RestripTest.NoRelations
               )

      assert_receive {:patched, %{"body" => body}}
      refute body =~ "auth.ex"
      refute body =~ "fable-7"
      assert body =~ "Task: #{id}"

      # The write is stamped, so the after-count no longer lists this issue.
      {:ok, after_doc} = Content.get_document(id, "task", @dataset, scope)
      assert %{"stripped" => true} = Link.get(after_doc)
      refute id in Restrip.plan(@dataset, scope).changed_ids
    end
  end

  defmodule NoProjects do
    @moduledoc false
    def sync(_task, _repo, _num, _link, _opts), do: :noop
  end

  defmodule NoRelations do
    @moduledoc false
    def hydrate_blocker_refs(task, _dataset, _opts), do: task
    def sync(_task, _repo, _num, _dataset, _opts), do: :noop
  end
end
