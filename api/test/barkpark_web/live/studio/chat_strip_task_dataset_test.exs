defmodule BarkparkWeb.Studio.ChatStripTaskDatasetTest do
  @moduledoc """
  The Doing strip subscribes to the dataset the task LEDGER is written in, not
  the socket's first-sorted dataset (task-ff3ed7ae0a242160).

  `ChatLive` mounts `dataset: default_dataset()` — the FIRST of the SORTED
  `Content.list_datasets/0`. The strip used to subscribe its document stream to
  that, while every task row (and so every claim, pulse and release frame) lives
  in `"production"`. On an install holding a dataset that sorts before
  `"production"` the live strip never received a frame; only a fresh hydrate
  showed claims.

  Every claim here is taken through the real writer (`Tasks.claim_by_id/3`), so
  the frame folded is the one `Content.Broadcast` actually publishes.

  HERMETIC. Both arms first delete every dataset that sorts before
  `"production"` (schema rows and documents) inside this test's sandbox
  transaction — the mechanism of #20038 — so committed residue from an unboxed
  test cannot decide which arm runs. The repro arm then ADDS its own
  uniquely-named early dataset, also inside the sandbox; everything is rolled
  back at exit and no other test sees it. Each arm asserts the dataset the view
  will mount on as a PRECONDITION rather than assuming it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.TaskLedgerScope
  alias Barkpark.Tasks
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Studio.ClaudeChat

  @admin_token "chat-strip-task-dataset-admin-token"
  @ledger "production"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()
    hide_datasets_sorting_before!(@ledger)
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    upsert_task_schemas!(@ledger, scope)
    Barkpark.LabelFixtures.register_tags!(@ledger)

    {:ok, _} =
      Auth.create_token(@admin_token, "strip admin", @ledger, ["read", "write", "admin"], ws.id)

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      Application.delete_env(:barkpark, :studio_chat_title_http_adapter)
      Application.delete_env(:barkpark, :studio_chat_title_cli)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token}), scope: scope}
  end

  # Runs inside this test's sandbox transaction: rolled back at exit.
  defp hide_datasets_sorting_before!(dataset) do
    Repo.delete_all(from(s in SchemaDefinition, where: s.dataset < ^dataset))
    Repo.delete_all(from(d in Document, where: d.dataset < ^dataset))
    :ok
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

    :ok
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Create + publish in the LEDGER dataset — the claim lives on the published
  # row and the strip ignores draft twins.
  defp task!(scope, title) do
    doc_id = uniq("stds")

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "strip dataset fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "the strip shows the claim", "met" => false}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, _draft} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => content},
        @ledger,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @ledger, scope)
    pub
  end

  defp open_session! do
    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"})
    {sid, ClaudeChat.worker_id(sid)}
  end

  defp strip_rows(html), do: Regex.scan(~r/data-role="chat-hand-task"/, html) |> length()

  # Mount FIRST, claim AFTER — so the only way the row can reach the strip is
  # the live `{:document_changed, …}` frame (the hydrate already ran, empty).
  defp claim_after_mount(conn, scope, title) do
    {sid, worker} = open_session!()
    {:ok, view, html} = live(conn, "/studio/chat/#{sid}")
    assert strip_rows(html) == 0, "precondition: the strip starts empty"

    t = task!(scope, title)
    {:ok, claimed} = Tasks.claim_by_id(t.doc_id, worker, scope)
    assert claimed.content["claim"]["worker"] == worker
    assert claimed.dataset == @ledger

    {view, render(view)}
  end

  test "the resolver names the ledger's dataset and the Default scope", %{scope: scope} do
    assert %{dataset: @ledger, workspace_id: ws_id, project_id: proj_id} =
             TaskLedgerScope.resolve(scope[:workspace_id])

    assert ws_id == scope[:workspace_id]
    assert proj_id == scope[:project_id]
  end

  test "POSITIVE CONTROL: with only the ledger dataset, a live claim reaches the strip",
       %{conn: conn, scope: scope} do
    assert hd(Content.list_datasets()) == @ledger,
           "precondition: the view mounts on #{inspect(@ledger)}"

    {_view, html} = claim_after_mount(conn, scope, "Only production exists")

    assert strip_rows(html) == 1
    assert html =~ "Only production exists"
  end

  test "a dataset sorting BEFORE the ledger does not steal the strip's subscription",
       %{conn: conn, scope: scope} do
    early = uniq("aaa-strip-early")
    upsert_task_schemas!(early, scope)

    # PRECONDITION: the view mounts on the early dataset, not the ledger's.
    assert hd(Content.list_datasets()) == early,
           "precondition: #{inspect(early)} must sort first, got " <>
             inspect(Content.list_datasets())

    {view, html} = claim_after_mount(conn, scope, "A claim in the ledger dataset")

    assert strip_rows(html) == 1,
           "the live claim did not reach the Doing strip: " <>
             "#{strip_rows(html)} [data-role=\"chat-hand-task\"] match(es); the view mounted on " <>
             "#{inspect(early)} while the claim was written in #{inspect(@ledger)}"

    assert html =~ "A claim in the ledger dataset"
    assert Process.alive?(view.pid)
  end
end
