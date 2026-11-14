defmodule BarkparkWeb.Studio.ChatPickerDatasetBoundTest do
  @moduledoc """
  The Studio chat's ready-task picker reads every dataset of the workspace when
  no dataset is named. A token minted with an explicit dataset is held to that
  one, so its picker lists that dataset's ready tasks only
  (task-fc15f525fea5d69e). An unbound token still sees both (control).
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability and the /studio/chat routes.
  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, StudioChat, Tasks, Tenancy}
  alias BarkparkWeb.Studio.ClaudeChat

  @own "bound-own"
  @prod "production"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup do
    Barkpark.ChatSessionResidue.purge!()
    enable_fake_chat()

    ws = create_workspace!("chat-bound-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id]

    tasks =
      for ds <- [@prod, @own], into: %{} do
        {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
        upsert_task_schemas!(ds, scope)
        Barkpark.LabelFixtures.register_tags!(ds)
        {ds, ready_task!(ds, scope, "CHAT-READY-IN-#{ds}")}
      end

    {:ok, ws: ws, tasks: tasks}
  end

  defp picker(ws, opts) do
    raw = "chat-bound-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "chat bound", @own, ["read", "write", "admin"], ws.id, opts)
    conn = scoped_conn() |> init_test_session(%{"api_token" => raw})

    {:ok, view, _} = live(conn, "/w/#{ws.slug}/p/default/studio/chat")
    html = render_click(view, "toggle-task-picker", %{})
    assert html =~ ~s(data-role="chat-task-picker")
    html
  end

  defp listed?(html, task), do: html =~ ~s(phx-value-id="#{task.doc_id}")

  test "a dataset-bound token's picker lists its own dataset's ready task only", ctx do
    html = picker(ctx.ws, dataset_bound: true)

    assert listed?(html, ctx.tasks[@own])
    refute listed?(html, ctx.tasks[@prod])
  end

  test "an unbound token's picker still lists both (control)", ctx do
    html = picker(ctx.ws, [])

    assert listed?(html, ctx.tasks[@own])
    assert listed?(html, ctx.tasks[@prod])
  end

  # The Doing strip: claims held by this chat session's worker. The hydrate
  # was narrowed with the picker; a live `document_changed` frame was not, so a
  # production claim still reached a bound token's strip until reload
  # (task-e59ce6fd3e7ab3f8).
  describe "the Doing strip" do
    defp strip(ws, tasks, opts, claim_when) do
      raw = "chat-bound-" <> Ecto.UUID.generate()
      perms = ["read", "write", "admin"]
      {:ok, _} = Auth.create_token(raw, "chat bound", @own, perms, ws.id, opts)
      conn = scoped_conn() |> init_test_session(%{"api_token" => raw})

      {:ok, session} =
        StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"}, {:workspace, ws.id})

      path = "/w/#{ws.slug}/p/default/studio/chat/#{session.id}"
      claim = fn -> claim_both!(tasks, ws, ClaudeChat.worker_id(session.id)) end

      if claim_when == :before_mount, do: claim.()
      {:ok, view, _} = live(conn, path)
      if claim_when == :after_mount, do: claim.()

      ~r/data-role="chat-hand-task"\s+data-task-id="([^"]+)"/
      |> Regex.scan(render(view), capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()
    end

    defp claim_both!(tasks, ws, worker) do
      for {ds, task} <- tasks do
        {:ok, _} = Tasks.claim_by_id(task.doc_id, worker, workspace_id: ws.id, dataset: ds)
      end
    end

    test "a dataset-bound token's strip hydrates with its own dataset's claim only",
         %{ws: ws, tasks: tasks} do
      own = [tasks[@own].doc_id]

      assert strip(ws, tasks, [dataset_bound: true], :before_mount) == own
    end

    test "a live frame for a production claim does not reach a bound token's strip",
         %{ws: ws, tasks: tasks} do
      refute tasks[@prod].doc_id in strip(ws, tasks, [dataset_bound: true], :after_mount)
    end

    test "an unbound token still gets the production claim by live frame (control)",
         %{ws: ws, tasks: tasks} do
      assert tasks[@prod].doc_id in strip(ws, tasks, [], :after_mount)
    end
  end

  defp upsert_task_schemas!(dataset, scope) do
    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  defp ready_task!(dataset, scope, title) do
    doc_id = "chat-bound-#{System.unique_integer([:positive])}"

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "fixture", "met" => false}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    attrs = %{"doc_id" => doc_id, "title" => title, "content" => content}
    {:ok, _} = Content.create_document("task", attrs, dataset, scope)
    {:ok, pub} = Content.publish_document(doc_id, "task", dataset, scope)
    pub
  end

  defp enable_fake_chat do
    keys = [
      :claude_chat,
      :public_demo_studio,
      :studio_chat_title_http_adapter,
      :studio_chat_title_cli
    ]

    prev = Map.new(keys, &{&1, Application.fetch_env(:barkpark, &1)})
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    on_exit(fn ->
      for {key, was} <- prev do
        case was do
          {:ok, value} -> Application.put_env(:barkpark, key, value)
          :error -> Application.delete_env(:barkpark, key)
        end
      end
    end)
  end
end
