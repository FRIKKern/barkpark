defmodule Barkpark.Tasks.PaperRefreshTest do
  @moduledoc """
  tlv-bl-web-task-cache-bust — a task CAS transition must reach the web front's
  paper cache through the webhook path when (and only when) a paper's task
  block QUERY resolves that task.

  Every case drives a REAL CAS verb (`Tasks.claim/2`, `Tasks.close/3`) against
  real rows and asserts on the delivery seam — the swappable
  `:webhook_http_adapter` records each signed POST the dispatcher makes — so a
  pass means a webhook actually left the building, not that a helper returned
  a list. The negative controls run the same verbs on tasks no paper queries
  and assert NOTHING is delivered.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures, Webhooks}
  alias Barkpark.Tasks.PaperRefresh

  @dataset "production"
  @hook_url "http://site.test/api/barkpark/webhook"

  defmodule RecordingHTTP do
    @moduledoc false
    @name __MODULE__

    def start do
      case Process.whereis(@name) do
        nil -> {:ok, _} = Agent.start_link(fn -> [] end, name: @name)
        _ -> Agent.update(@name, fn _ -> [] end)
      end

      :ok
    end

    def calls, do: Agent.get(@name, & &1) |> Enum.reverse()

    def post(url, body, _headers) do
      at = System.monotonic_time(:millisecond)

      Agent.update(@name, fn calls -> [%{url: url, body: Jason.decode!(body), at: at} | calls] end)

      {:ok, 200}
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

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

    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    prev_mode = Application.get_env(:barkpark, :task_paper_refresh)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    Application.put_env(:barkpark, :task_paper_refresh, :sync)
    :ok = RecordingHTTP.start()

    on_exit(fn ->
      restore(:webhook_http_adapter, prev_adapter)
      restore(:task_paper_refresh, prev_mode)
    end)

    # The site's content webhook, exactly as realtime-webhook-setup registers
    # it: the paper type, the ordinary content events.
    {:ok, _hook} =
      Webhooks.create_webhook(
        %{
          "name" => "site",
          "url" => @hook_url,
          "dataset" => @dataset,
          "secret" => "sek",
          "events" => ["create", "update", "publish", "unpublish", "delete"],
          "types" => ["paper"]
        },
        workspace_id: ws.id,
        project_id: project.id
      )

    %{scope: scope}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, v), do: Application.put_env(:barkpark, key, v)

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  defp mk_task!(scope, extra) do
    doc_id = uniq("prt")

    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "fixture is closeable", "met" => true}]
        },
        extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp mk_paper!(blocks) do
    slug = uniq("prt-paper")

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, style: "article", blocks: blocks})
      )

    paper
  end

  defp board(query), do: %{"id" => uniq("b"), "type" => "task-board", "query" => query}

  defp claim!(scope, phase) do
    {:ok, claimed} = Tasks.claim("w-prt", scope ++ [phase_id: phase, dataset: @dataset])
    claimed
  end

  defp close!(claimed) do
    {:ok, closed} =
      Tasks.close(claimed.id, "w-prt",
        observed_epoch: claimed.content["claim"]["epoch"],
        observed_rev: claimed.rev,
        lifecycle_status: "done"
      )

    closed
  end

  defp drain do
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

  defp paper_posts do
    drain()
    Enum.filter(RecordingHTTP.calls(), &(&1.url == @hook_url))
  end

  describe "a referenced task transition" do
    test "a claim dispatches the paper webhook the web busts on, inside the bound", %{
      scope: scope
    } do
      epic = uniq("epic")
      _task = mk_task!(scope, %{"parent_id" => epic})
      paper = mk_paper!([board(%{"parent_id" => epic})])

      t0 = System.monotonic_time(:millisecond)
      _claimed = claim!(scope, epic)

      assert [post] = paper_posts()
      latency_ms = post.at - t0

      assert post.body["type"] == "paper"
      assert post.body["event"] == "update"
      assert post.body["doc_id"] == paper.doc_id
      assert "bp:ds:#{@dataset}:type:paper" in post.body["sync_tags"]

      # The promised bound: webhook POSTed within 1 s of the CAS verb being
      # called (the verb's own transaction included).
      assert latency_ms < 1_000, "paper webhook took #{latency_ms} ms"

      if System.get_env("PAPER_REFRESH_LATENCY"),
        do: IO.puts("\n[paper-refresh] claim → paper webhook POST: #{latency_ms} ms")
    end

    test "a task LEAVING a status-filtered, column-nested board still dispatches", %{
      scope: scope
    } do
      epic = uniq("epic")
      _task = mk_task!(scope, %{"parent_id" => epic})

      # The board lists only OPEN tasks; after the claim the task no longer
      # matches the query — the post-write row alone would miss the change.
      _paper =
        mk_paper!([
          %{
            "id" => uniq("cols"),
            "type" => "columns",
            "columns" => [[board(%{"parent_id" => epic, "status" => "open"})], []]
          }
        ])

      _claimed = claim!(scope, epic)

      assert [%{body: %{"type" => "paper"}}] = paper_posts()
    end

    test "closing an off-board blocker refreshes the board its dependent sits on", %{
      scope: scope
    } do
      epic = uniq("epic")
      blocker_phase = uniq("elsewhere")
      blocker = mk_task!(scope, %{"parent_id" => blocker_phase})
      dependent = mk_task!(scope, %{"parent_id" => epic})
      {:ok, _} = Tasks.add_dep(dependent.id, blocker.id, :blocks)
      _paper = mk_paper!([board(%{"parent_id" => epic})])

      claimed = claim!(scope, blocker_phase)

      # The claim alone is a no-op for the paper: the blocker is not on the
      # board, and its dependent's row cannot change until the blocker is done.
      assert paper_posts() == []

      _closed = close!(claimed)

      assert [%{body: %{"type" => "paper"}}] = paper_posts()
    end

    test "a lease reap (TtlSweeper, no CAS verb) refreshes the board", %{scope: scope} do
      epic = uniq("epic")
      _task = mk_task!(scope, %{"parent_id" => epic})
      _paper = mk_paper!([board(%{"parent_id" => epic})])

      claimed = claim!(scope, epic)
      assert [_claim_post] = paper_posts()
      :ok = RecordingHTTP.start()

      # Age the lease past the sweep TTL, then reap: in_progress → open.
      stale_ts = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_iso8601()
      content = put_in(claimed.content, ["claim", "ts_iso"], stale_ts)

      {1, _} =
        Ecto.Query.from(d in Barkpark.Content.Document, where: d.id == ^claimed.id)
        |> Repo.update_all(set: [content: content])

      assert %{swept: swept} = Barkpark.Tasks.TtlSweeper.sweep(300)
      assert swept >= 1

      assert [%{body: %{"type" => "paper", "event" => "update"}}] = paper_posts()
    end
  end

  describe "negative control" do
    test "claim + close of a task no paper queries dispatches nothing", %{scope: scope} do
      epic = uniq("epic")
      other = uniq("unrelated")
      _on_board = mk_task!(scope, %{"parent_id" => epic})
      _unrelated = mk_task!(scope, %{"parent_id" => other})
      _paper = mk_paper!([board(%{"parent_id" => epic})])

      claimed = claim!(scope, other)
      _closed = close!(claimed)

      assert paper_posts() == [],
             "an unrelated task transition must not invalidate the paper"

      # And the same paper IS live: the control is not passing because the
      # seam is dead.
      _ = claim!(scope, epic)
      assert [_] = paper_posts()
    end

    test "heartbeat kinds are skipped before any lookup", %{scope: scope} do
      epic = uniq("epic")
      task = mk_task!(scope, %{"parent_id" => epic})
      _paper = mk_paper!([board(%{"parent_id" => epic})])

      assert PaperRefresh.refresh([
               %{doc: task, kind: "task.pulse", event_id: 1, previous_rev: nil},
               %{doc: task, kind: "task.lease_renewed", event_id: 1, previous_rev: nil}
             ]) == []

      assert paper_posts() == []
    end
  end
end
