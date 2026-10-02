defmodule Barkpark.Plugins.Github.LinkForgeryTest do
  @moduledoc """
  Async authz sweep (r4a): `content.github` was writable by any task writer.

  `RetireJob` closes `link["repo"]#link["issue"]` when a task is deleted, and
  `MirrorJob` PATCHes `link["issue"]`, both with the instance GitHub App's
  token. Nothing reserved the field, so a writer could hand-write a link to an
  issue the bridge never created (in ANY repo the App reaches) and then delete
  the task to make the App close it. `LinkFence` now refuses a user-door write
  that adds or changes the link; the bridge's own writes still pass.
  """

  use Barkpark.DataCase, async: false

  # Plugins-off: the github plugin starts Plugins.Github.Auth and owns intake, mirror and webhooks
  @moduletag :requires_plugins
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.Lifecycle
  alias Barkpark.Plugins.Github.{Auth, Link}

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

  @victim "victim-org/victim-repo"

  test "a user write cannot FORGE a link on a task", %{scope: scope} do
    id = uniq("gh")
    _task = mk_task!(id, %{"title" => "Forger"}, scope)

    result =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => Content.draft_id(id),
          "title" => "Forger",
          "content" => %{"github" => %{"repo" => @victim, "issue" => 77, "state" => "synced"}}
        },
        @dataset,
        scope
      )

    assert match?({:error, _}, result), "a user write stored a forged content.github link"

    {:ok, doc} = Content.get_document(id, "task", @dataset, scope)
    assert Link.get(doc) in [nil, %{}]
  end

  test "deleting a task whose link was forged makes the App close nothing", %{
    bypass: bypass,
    scope: scope
  } do
    stub_token(bypass)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    Bypass.stub(bypass, "PATCH", "/repos/#{@victim}/issues/77", fn conn ->
      Agent.update(calls, &[:patched | &1])
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"number" => 77, "state" => "closed"}))
    end)

    id = uniq("gh")
    task = mk_task!(id, %{"title" => "Forger"}, scope)
    forged = %{"repo" => @victim, "issue" => 77, "state" => "synced"}

    _ =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => Content.draft_id(id),
          "title" => "Forger",
          "content" => Map.put(task.content, "github", forged)
        },
        @dataset,
        scope
      )

    # Publishing carries the draft's content (and so the forged link) onto the
    # published row the delete hook reads.
    _ = Content.publish_document(id, "task", @dataset, scope)

    {:ok, _} = Barkpark.Content.Lifecycle.delete_document(id, "task", @dataset, scope)
    _ = drain()

    assert Agent.get(calls, & &1) == [],
           "the App closed an issue in a repo named only by a user-written link"
  end

  test "the bridge's own Link.put still writes the link (control)", %{scope: scope} do
    id = uniq("gh")
    _task = mk_task!(id, %{"title" => "Mirrored"}, scope)
    {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 5, state: "synced"}, scope)

    {:ok, doc} = Content.get_document(id, "task", @dataset, scope)
    assert Link.get(doc)["issue"] == 5
  end

  test "an ordinary edit that keeps the link unchanged still saves (control)", %{scope: scope} do
    id = uniq("gh")
    _task = mk_task!(id, %{"title" => "Mirrored"}, scope)
    {:ok, _} = Link.put(id, @dataset, %{repo: @repo, issue: 6, state: "synced"}, scope)
    {:ok, doc} = Content.get_document(id, "task", @dataset, scope)

    assert {:ok, _} =
             Content.upsert_document(
               "task",
               %{
                 "doc_id" => Content.draft_id(id),
                 "title" => "Mirrored, renamed",
                 "content" => doc.content
               },
               @dataset,
               scope
             )
  end
end
