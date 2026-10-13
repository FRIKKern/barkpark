defmodule Barkpark.Plugins.Github.UnpublishRetireTest do
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

  # Plugins-off: the github plugin starts Plugins.Github.Auth and owns intake, mirror and webhooks
  @moduletag :requires_plugins
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
  # task-2cdf028b51e25cac — an unpublish keeps an EXISTING draft as it is. A draft
  # forked BEFORE the mirror wrote content.github onto the published row carries
  # no issue link, so MirrorJob's retraction (which reads the draft first) found
  # no number and cancelled `:unpublished`, leaving the issue OPEN with no
  # published row behind it. The :after_unpublish hook now reads the number off
  # the just-unpublished PUBLISHED row and enqueues the close, the way the
  # delete path already does.
  describe "unpublish_document/4 — a kept draft without the link" do
    test "unpublishing a mirrored task whose draft lacks content.github still closes the issue",
         %{bypass: bypass, scope: scope} do
      stub_token(bypass)
      id = uniq("gh")
      num = 2360

      _task = mk_task!(id, %{"title" => "Mirrored, with an older draft"}, scope)

      # The draft is forked BEFORE the link is written (Link.put is
      # published-first, so it never reaches this draft).
      {:ok, _draft} =
        Content.upsert_document(
          "task",
          %{"doc_id" => Content.draft_id(id), "title" => "Draft edit"},
          @dataset,
          scope
        )

      {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: num, state: "synced"}, scope)

      assert {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert Link.get(published)["issue"] == num
      assert {:ok, draft} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      assert Link.get(draft) in [nil, %{}], "precondition: the draft carries no link"

      calls = record_patches(bypass, num)
      assert {:ok, _} = Lifecycle.unpublish_document(id, "task", @dataset, scope)
      drain()

      closes = Enum.filter(patches(calls), &(&1["state"] == "closed"))

      assert closes != [],
             "issue ##{num} stayed OPEN after the unpublish (patches: #{inspect(patches(calls))})"

      assert hd(closes)["state_reason"] == "not_planned"
    end

    test "CONTROL: republished before the job runs, the issue is not closed", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, %{"title" => "Unpublished then republished"}, scope)

      args = %{
        "doc_id" => id,
        "dataset" => @dataset,
        "repo" => @repo,
        "issue" => 2361,
        "mode" => "unpublished"
      }

      args =
        Map.merge(args, %{
          "workspace_id" => scope[:workspace_id],
          "project_id" => scope[:project_id]
        })

      assert {:cancel, :task_returned} = perform_job(RetireJob, args)
    end
  end
end
