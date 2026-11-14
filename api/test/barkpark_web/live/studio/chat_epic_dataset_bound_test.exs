defmodule BarkparkWeb.Studio.ChatEpicDatasetBoundTest do
  @moduledoc """
  The Studio chat's two epic reads follow a held claim to its parent and read
  that parent's children across every dataset of the workspace: the Doing
  strip's agent lines, and the sidebar's epic-goal line. A token minted with an
  explicit dataset is held to that one, so neither read may hand it another
  dataset's task (task-b5b071d20c6956f9). An unbound token sees both (control).
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability and the /studio/chat routes.
  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, StudioChat, Tasks, Tenancy}
  alias Barkpark.StudioChat.AgentTaskJoin
  alias BarkparkWeb.Studio.ClaudeChat

  @own "bound-own"
  @prod "production"

  @prod_child "PRODUCTION SIBLING the bound token must not see"
  @prod_pulse "production-only now line"
  @prod_epic "PRODUCTION EPIC the bound token must not see"
  @own_epic "Own dataset epic"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup do
    Barkpark.ChatSessionResidue.purge!()
    enable_fake_chat()

    ws = create_workspace!("chat-epic-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id]

    for ds <- [@prod, @own] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
      upsert_task_schemas!(ds, scope)
      Barkpark.LabelFixtures.register_tags!(ds)
    end

    {:ok, ws: ws, scope: scope}
  end

  # A session whose worker holds an OWN-dataset slice under `epic`, with a
  # production sibling under the same epic claimed and pulsed by a builder the
  # session's rail names. Returns the mounted view's HTML and the sibling.
  defp mount_chat(ws, scope, epic_dataset, epic_title, token_opts) do
    sid = Ecto.UUID.generate()
    label = "build:" <> AgentTaskJoin.emitter_slug(@prod_child)
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws.id})
    {:ok, _} = StudioChat.set_rail_snapshot(sid, rail_with(label))

    epic = task!(epic_dataset, scope, epic_title, %{})
    slice = task!(@own, scope, "Own slice", %{"parent_id" => epic.doc_id})
    claim!(slice, ClaudeChat.worker_id(sid), ws, @own)

    sibling = task!(@prod, scope, @prod_child, %{"parent_id" => epic.doc_id})
    builder = "epic-builder-" <> AgentTaskJoin.emitter_slug(@prod_child)
    claim!(sibling, builder, ws, @prod)
    {:ok, _} = Tasks.pulse_by_id(sibling.id, builder, text: @prod_pulse)

    raw = "chat-epic-" <> Ecto.UUID.generate()
    perms = ["read", "write", "admin"]
    {:ok, _} = Auth.create_token(raw, "chat epic", @own, perms, ws.id, token_opts)
    conn = scoped_conn() |> init_test_session(%{"api_token" => raw})

    {:ok, view, _} = live(conn, "/w/#{ws.slug}/p/default/studio/chat/#{sid}")
    %{html: render(view), view: view, sid: sid, sibling: sibling, slice: slice}
  end

  defp epic_line(%{view: view, sid: sid}) do
    sel = ~s([data-test-id="chat-epic-#{sid}"])
    if has_element?(view, sel), do: view |> element(sel) |> render()
  end

  defp agent_line?(%{html: html, sibling: sibling}),
    do: html =~ ~s(data-role="chat-agent-task") and html =~ ~s(data-task-id="#{sibling.doc_id}")

  describe "an epic in the token's own dataset with a production sibling" do
    test "a dataset-bound token gets no agent line for the production sibling",
         %{ws: ws, scope: scope} do
      m = mount_chat(ws, scope, @own, @own_epic, dataset_bound: true)

      # The strip itself is up: the own-dataset claim is on it.
      assert m.html =~ ~s(data-task-id="#{m.slice.doc_id}")
      refute agent_line?(m)
      refute m.html =~ @prod_pulse
      refute m.html =~ m.sibling.doc_id
    end

    test "a dataset-bound token's epic line counts its own dataset's slices only",
         %{ws: ws, scope: scope} do
      line = epic_line(mount_chat(ws, scope, @own, @own_epic, dataset_bound: true))

      assert line =~ @own_epic
      assert line =~ "0/1 slices"
    end

    test "an unbound token still gets the agent line and both slices (control)",
         %{ws: ws, scope: scope} do
      m = mount_chat(ws, scope, @own, @own_epic, [])

      assert agent_line?(m)
      assert m.html =~ @prod_pulse
      assert epic_line(m) =~ "0/2 slices"
    end
  end

  describe "an epic in production over an own-dataset claim" do
    test "a dataset-bound token's sidebar does not carry the production epic",
         %{ws: ws, scope: scope} do
      m = mount_chat(ws, scope, @prod, @prod_epic, dataset_bound: true)

      assert m.html =~ ~s(data-task-id="#{m.slice.doc_id}")
      refute m.html =~ @prod_epic
      assert epic_line(m) == nil
      refute agent_line?(m)
    end

    test "an unbound token still reads the production epic (control)",
         %{ws: ws, scope: scope} do
      m = mount_chat(ws, scope, @prod, @prod_epic, [])

      assert epic_line(m) =~ @prod_epic
      assert agent_line?(m)
    end
  end

  defp claim!(task, worker, ws, dataset) do
    {:ok, _} = Tasks.claim_by_id(task.doc_id, worker, workspace_id: ws.id, dataset: dataset)
  end

  # A workflow rail whose Build phase carries one agent label, the shape
  # `StudioChat.set_rail_snapshot/2` persists and a reopen hydrates.
  defp rail_with(label) do
    %{
      "wf" => %{
        "status" => "running",
        "seq" => 1,
        "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Build"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => label,
            "state" => "progress",
            "startedAt" => 100
          }
        ]
      }
    }
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

  defp task!(dataset, scope, title, extra) do
    doc_id = "chat-epic-#{System.unique_integer([:positive])}"

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
      |> Map.merge(extra)

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
