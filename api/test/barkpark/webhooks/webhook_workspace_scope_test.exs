defmodule Barkpark.Webhooks.WebhookWorkspaceScopeTest do
  @moduledoc """
  Cross-tenant webhook leak guard (Wave 1.5, B4).

  Before this fix, webhooks were scoped by `dataset` only — so a content change
  in workspace B selected (and delivered to) workspace A's webhooks, and the
  webhook CRUD listing returned webhooks across every workspace. These tests
  stand up TWO distinct workspaces in the SAME dataset and prove:

    1. `Webhooks.active_webhooks_for/4` scoped to B never SELECTS A's webhook,
    2. `Dispatcher.dispatch_async/7` carrying B's scope never DELIVERS to A's
       webhook (no HTTP call lands on it), and
    3. `Webhooks.list_webhooks/2` (the CRUD listing) scoped to B never RETURNS
       A's webhook.

  Isolation must come from `workspace_id`, never the dataset leaf — both
  workspaces share `@dataset`.
  """
  use Barkpark.DataCase, async: false
  import Ecto.Query

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher

  # Same dataset in BOTH workspaces — the leak must be caught by workspace_id.
  @dataset "test"
  @event "publish"
  @doctype "post"

  # Records every HTTP POST so we can assert which webhook URLs were delivered
  # to (or, for the leak guard, were NOT delivered to). Backed by an Agent so
  # the supervised delivery Tasks can record into shared state.
  defmodule RecordingHTTP do
    @name __MODULE__

    def start do
      case Process.whereis(@name) do
        nil -> {:ok, _} = Agent.start_link(fn -> [] end, name: @name)
        _ -> Agent.update(@name, fn _ -> [] end)
      end

      :ok
    end

    def urls, do: Agent.get(@name, & &1) |> Enum.reverse()

    def post(url, _body, _headers) do
      Agent.update(@name, fn calls -> [url | calls] end)
      {:ok, 200}
    end
  end

  setup do
    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    :ok = RecordingHTTP.start()

    on_exit(fn ->
      case prev_adapter do
        nil -> Application.delete_env(:barkpark, :webhook_http_adapter)
        v -> Application.put_env(:barkpark, :webhook_http_adapter, v)
      end
    end)

    # Register the doc type so the delivery tests can create real documents
    # (and thus real mutation_events, whose id claim_delivery's FK requires).
    Content.upsert_schema(
      %{"name" => @doctype, "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    # Webhook registered in workspace A only. Fires on the @event/@doctype pair.
    {:ok, wh_a} =
      Webhooks.create_webhook(
        %{
          "name" => "ws-a-hook",
          "url" => "http://ws-a.test/hook",
          "dataset" => @dataset,
          "secret" => "sek-a",
          "events" => [@event],
          "types" => [@doctype]
        },
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b, wh_a: wh_a}
  end

  describe "active_webhooks_for/4 selection" do
    test "A's webhook is selected under A's scope, NOT under B's", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      wh_a: wh_a
    } do
      reader = fn scope ->
        Webhooks.active_webhooks_for(@dataset, @event, @doctype, scope)
      end

      assert :ok =
               assert_no_cross_workspace_leak(
                 reader,
                 ws_a,
                 proj_a,
                 ws_b,
                 proj_b,
                 & &1.id,
                 wh_a.id
               )
    end
  end

  describe "dispatch_async/7 delivery" do
    test "a content change in B does NOT deliver to A's webhook", %{
      ws_b: ws_b,
      proj_b: proj_b,
      wh_a: wh_a
    } do
      # A real content mutation in workspace B → a real mutation_event id.
      {doc_id, event_id} = real_event!(ws_b, proj_b, "doc-in-b")

      # Dispatch carries B's workspace/project scope (exactly what
      # tap_broadcast threads). A's webhook must not be selected, so no HTTP
      # POST may land on A's URL.
      Dispatcher.dispatch_async(
        @dataset,
        @event,
        @doctype,
        doc_id,
        %{"_id" => doc_id},
        event_id,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

      # Wait for any spawned delivery Tasks to finish before asserting.
      drain_delivery_tasks()

      refute wh_a.url in RecordingHTTP.urls(),
             "CROSS-WORKSPACE LEAK: a content change in workspace B delivered to " <>
               "workspace A's webhook (#{wh_a.url})"
    end

    test "a content change in A DOES deliver to A's webhook (sanity)", %{
      ws_a: ws_a,
      proj_a: proj_a,
      wh_a: wh_a
    } do
      {doc_id, event_id} = real_event!(ws_a, proj_a, "doc-in-a")

      Dispatcher.dispatch_async(
        @dataset,
        @event,
        @doctype,
        doc_id,
        %{"_id" => doc_id},
        event_id,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

      drain_delivery_tasks()

      assert wh_a.url in RecordingHTTP.urls(),
             "expected A's own content change to deliver to A's webhook"
    end
  end

  describe "list_webhooks/2 (CRUD listing)" do
    test "A's webhook is listed under A's scope, NOT under B's", %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      wh_a: wh_a
    } do
      reader = fn scope -> Webhooks.list_webhooks(@dataset, scope) end

      assert :ok =
               assert_no_cross_workspace_leak(
                 reader,
                 ws_a,
                 proj_a,
                 ws_b,
                 proj_b,
                 & &1.id,
                 wh_a.id
               )
    end
  end

  # Create a real document in `(ws, proj)` and return its `{doc_id, event_id}`.
  # claim_delivery's FK requires a real mutation_events.id, so the dispatch
  # tests can't use a fabricated event id. Creating the doc also fires its own
  # "create" broadcast, but the seed webhook only listens for `@event`
  # ("publish") so that create never delivers — keeping the recorded URLs clean.
  defp real_event!(ws, proj, doc_id) do
    {:ok, doc} =
      Content.create_document(@doctype, %{"_id" => doc_id, "title" => "t"}, @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    [ev | _] =
      Barkpark.Repo.all(
        from(e in Barkpark.Content.MutationEvent,
          where: e.doc_id == ^doc.doc_id,
          order_by: [desc: e.id]
        )
      )

    {doc.doc_id, ev.id}
  end

  # Deliveries run as supervised Tasks under Barkpark.TaskSupervisor; await all
  # in-flight children so the recorded-URL assertions see the final state.
  defp drain_delivery_tasks do
    Barkpark.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> :ok
      end
    end)
  end
end
