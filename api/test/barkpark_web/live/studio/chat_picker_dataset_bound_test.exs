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

  alias Barkpark.{Auth, Content, Tasks, Tenancy}

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
