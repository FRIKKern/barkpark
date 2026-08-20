defmodule BarkparkWeb.GithubWebhookControllerTest do
  @moduledoc """
  Wave 3 slice 3 — the webhook controller's event-gate + intake dispatch.

  Slices 1 (raw-body cache + signature plug + router `:github_webhook`
  pipeline) and 2 (`Github.Intake`) are sibling slices not yet in this tree, so
  these tests drive the controller ACTION directly and inject the Intake call
  through the documented seam (`config :barkpark, :github_webhook_intake_fun`).
  That isolates exactly what THIS slice owns: read `X-GitHub-Event`, forward
  `issues` deliveries to Intake with the dataset threaded, and answer 2xx on
  every verified-but-unactionable delivery so GitHub never retry-storms. The
  full router→signature→intake→task-birth path is exercised at integration
  time, once slices 1+2 land.
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.GithubWebhookController

  @issue_opened %{
    "action" => "opened",
    "issue" => %{"number" => 42, "title" => "Outsider bug", "body" => "it broke"},
    "sender" => %{"type" => "User", "login" => "octocat"}
  }

  setup do
    on_exit(fn ->
      Application.delete_env(:barkpark, :github_webhook_intake_fun)
      Application.delete_env(:barkpark, :github_webhook_inbound_fun)
      Application.delete_env(:barkpark, :github_webhook_merge_events_fun)
    end)

    :ok
  end

  # Inject a stub Intake that records its call and returns `result`. Runs in the
  # test process (the action is invoked synchronously), so `self()` is the test.
  defp stub_intake(result) do
    test = self()

    Application.put_env(:barkpark, :github_webhook_intake_fun, fn payload, opts ->
      send(test, {:intake_called, payload, opts})
      result
    end)
  end

  # Inject a stub InboundEvents handler (the D14 detach path) mirroring the
  # Intake seam. Records its call so a test can assert which handler ran.
  defp stub_inbound(result) do
    test = self()

    Application.put_env(:barkpark, :github_webhook_inbound_fun, fn payload, opts ->
      send(test, {:inbound_called, payload, opts})
      result
    end)
  end

  # Inject a stub MergeEvents handler (the pull_request merge-reconcile path)
  # mirroring the Intake/InboundEvents seams. Records its call.
  defp stub_merge_events(result) do
    test = self()

    Application.put_env(:barkpark, :github_webhook_merge_events_fun, fn payload, opts ->
      send(test, {:merge_events_called, payload, opts})
      result
    end)
  end

  defp deliver(event, params) do
    build_conn()
    |> put_req_header("x-github-event", event)
    |> GithubWebhookController.receive(params)
  end

  describe "issues event → Intake dispatch" do
    test "opened issue forwards the payload to Intake and answers 200" do
      # The real Intake reports a 3-tuple (`{:ok, :born, doc}`) — stub that exact
      # shape, not a 2-tuple, so this test can't pass while prod CaseClauseErrors.
      stub_intake({:ok, :born, %{"_id" => "gh-42"}})

      conn = deliver("issues", @issue_opened)

      assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)
      assert_received {:intake_called, payload, opts}
      assert payload == @issue_opened
      # dataset threaded from Settings.datasets/0 (env-default "production")
      assert Keyword.get(opts, :dataset) == "production"
    end

    test "the configured mirror dataset (not the default) is threaded to Intake" do
      prev = Application.get_env(:barkpark, Barkpark.Plugins.Github)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, Barkpark.Plugins.Github, prev),
          else: Application.delete_env(:barkpark, Barkpark.Plugins.Github)
      end)

      Application.put_env(:barkpark, Barkpark.Plugins.Github,
        github_mirror_datasets: ["staging", "production"]
      )

      stub_intake({:ok, :born, %{"_id" => "gh-42"}})

      conn = deliver("issues", @issue_opened)

      assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)
      assert_received {:intake_called, _payload, opts}
      # first of the configured list — the controller owns the choice
      assert Keyword.get(opts, :dataset) == "staging"
    end

    test "bot-drop result (:dropped) answers 200 — never a retry-storm on a loop cut" do
      stub_intake(:dropped)

      conn = deliver("issues", @issue_opened)

      assert %{"ok" => true, "dropped" => true} = json_response(conn, 200)
      # controller still forwarded — the drop is Intake's decision (D4 cut #1)
      assert_received {:intake_called, _payload, _opts}
    end

    test "a non-opened, non-inbound action (edited → :ignored) answers 202 via Intake" do
      # `edited` is NOT one of the D14 inbound actions (deleted/transferred/
      # closed), so it still routes to Intake, which ignores it.
      stub_intake(:ignored)

      conn = deliver("issues", Map.put(@issue_opened, "action", "edited"))

      assert %{"ok" => true, "ignored" => "action"} = json_response(conn, 202)
      assert_received {:intake_called, _payload, _opts}
      refute_received {:inbound_called, _payload, _opts}
    end

    test "a genuine intake failure ({:error, _}) answers 5xx so GitHub redelivers" do
      stub_intake({:error, :db_unavailable})

      conn = deliver("issues", @issue_opened)

      assert %{"error" => %{"code" => "intake_failed"}} = json_response(conn, 500)
      assert_received {:intake_called, _payload, _opts}
    end

    test "the X-GitHub-Event value is matched case-insensitively" do
      stub_intake({:ok, :born, %{"_id" => "gh-42"}})

      conn = deliver("Issues", @issue_opened)

      assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)
      assert_received {:intake_called, _payload, _opts}
    end

    test "an idempotent re-delivery (:exists 3-tuple) also answers 200" do
      # A re-delivery short-circuits in Intake to `{:ok, :exists, doc}`; the
      # controller must accept both `:ok` tags, not just `:born`.
      stub_intake({:ok, :exists, %{"_id" => "gh-42"}})

      conn = deliver("issues", @issue_opened)

      assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)
      assert_received {:intake_called, _payload, _opts}
    end

    test "a dedup-refused intake ({:refused, _}) answers 202 — never a retry-storm" do
      # The outsider issue looked like existing tracked work. Intake already
      # posted the maintainer comment + recorded a findable dead-letter row, so
      # a 5xx would only double-post — the controller must answer 2xx.
      stub_intake({:refused, "gh-42"})

      conn = deliver("issues", @issue_opened)

      assert %{"ok" => true, "refused" => true} = json_response(conn, 202)
      assert_received {:intake_called, _payload, _opts}
    end
  end

  describe "inbound-event dispatch (D14) → InboundEvents, not Intake" do
    for action <- ["deleted", "transferred", "closed"] do
      @action action

      test "#{@action} routes to InboundEvents (not Intake) and a detach answers 200" do
        stub_inbound({:ok, :detached, "gh-42"})
        # If dispatch wrongly hit Intake, this stub would run and the assertion
        # below (inbound_called) would fail — the routing is the thing under test.
        stub_intake({:ok, :should_not_run})

        conn = deliver("issues", Map.put(@issue_opened, "action", @action))

        assert %{"ok" => true, "detached" => true} = json_response(conn, 200)
        assert_received {:inbound_called, _payload, opts}
        assert Keyword.get(opts, :dataset) == "production"
        refute_received {:intake_called, _payload, _opts}
      end
    end

    test "a :dropped inbound outcome (bot close echo) answers 200 — no retry-storm" do
      stub_inbound(:dropped)

      conn = deliver("issues", Map.put(@issue_opened, "action", "closed"))

      assert %{"ok" => true, "dropped" => true} = json_response(conn, 200)
      assert_received {:inbound_called, _payload, _opts}
    end

    test "an :ignored inbound outcome (missing/non-intake) answers 202 no-op" do
      stub_inbound(:ignored)

      conn = deliver("issues", Map.put(@issue_opened, "action", "deleted"))

      assert %{"ok" => true, "ignored" => "action"} = json_response(conn, 202)
      assert_received {:inbound_called, _payload, _opts}
    end

    test "a genuine inbound failure ({:error, _}) answers 5xx so GitHub redelivers" do
      stub_inbound({:error, :db_unavailable})

      conn = deliver("issues", Map.put(@issue_opened, "action", "transferred"))

      assert %{"error" => %{"code" => "inbound_failed"}} = json_response(conn, 500)
      assert_received {:inbound_called, _payload, _opts}
    end

    test "opened still routes to Intake, never InboundEvents" do
      stub_intake({:ok, :born, %{"_id" => "gh-42"}})
      stub_inbound({:ok, :detached, "gh-42"})

      conn = deliver("issues", @issue_opened)

      assert %{"ok" => true, "ingested" => true} = json_response(conn, 200)
      assert_received {:intake_called, _payload, _opts}
      refute_received {:inbound_called, _payload, _opts}
    end
  end

  describe "intake workspace threading (D15)" do
    @intake_ws_env "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"

    setup do
      prev = System.get_env(@intake_ws_env)
      System.delete_env(@intake_ws_env)

      on_exit(fn ->
        if prev,
          do: System.put_env(@intake_ws_env, prev),
          else: System.delete_env(@intake_ws_env)
      end)

      :ok
    end

    test "env-configured workspace threads as :workspace_id into BOTH handlers' opts" do
      System.put_env(@intake_ws_env, "ws-uuid-42")

      stub_intake({:ok, :born, %{"_id" => "gh-1"}})
      deliver("issues", @issue_opened)
      assert_received {:intake_called, _payload, intake_opts}
      assert Keyword.get(intake_opts, :workspace_id) == "ws-uuid-42"

      stub_inbound(:ignored)
      deliver("issues", Map.put(@issue_opened, "action", "deleted"))
      assert_received {:inbound_called, _payload, inbound_opts}
      assert Keyword.get(inbound_opts, :workspace_id) == "ws-uuid-42"
    end

    test "absent env var adds NO :workspace_id key — opts are byte-identical to before D15" do
      stub_intake({:ok, :born, %{"_id" => "gh-1"}})
      deliver("issues", @issue_opened)

      assert_received {:intake_called, _payload, opts}
      refute Keyword.has_key?(opts, :workspace_id)
      assert opts == [dataset: "production"]
    end
  end

  describe "non-issues deliveries never touch Intake" do
    test "ping handshake answers 200 without calling Intake" do
      stub_intake({:ok, :should_not_run})

      conn = deliver("ping", %{"zen" => "Keep it logically awesome.", "hook_id" => 1})

      assert %{"ok" => true} = json_response(conn, 200)
      refute_received {:intake_called, _payload, _opts}
    end

    test "an unhandled event answers 202 no-op without calling Intake" do
      stub_intake({:ok, :should_not_run})

      conn = deliver("push", %{"ref" => "refs/heads/main"})

      assert %{"ok" => true, "ignored" => "event"} = json_response(conn, 202)
      refute_received {:intake_called, _payload, _opts}
    end

    test "a missing X-GitHub-Event header answers 202 no-op (never crashes)" do
      stub_intake({:ok, :should_not_run})

      conn = GithubWebhookController.receive(build_conn(), %{})

      assert %{"ok" => true, "ignored" => "event"} = json_response(conn, 202)
      refute_received {:intake_called, _payload, _opts}
    end
  end

  describe "pull_request event → MergeEvents merge-reconcile dispatch" do
    @merged_pr %{
      "action" => "closed",
      "pull_request" => %{
        "number" => 4621,
        "merged" => true,
        "merge_commit_sha" => "abc1234",
        "body" => "Task: ledger-merge-criterion-autostamp"
      }
    }

    test "a merged PR forwards to MergeEvents and answers 200 stamped" do
      stub_merge_events({:ok, :stamped, "ledger-merge-criterion-autostamp", [4]})

      conn = deliver("pull_request", @merged_pr)

      assert %{"ok" => true, "stamped" => true, "task" => "ledger-merge-criterion-autostamp"} =
               json_response(conn, 200)

      assert_received {:merge_events_called, payload, opts}
      assert payload == @merged_pr
      assert Keyword.get(opts, :dataset) == "production"
    end

    test "a named idempotent outcome (:already_stamped) answers 200 reconciled" do
      stub_merge_events({:ok, :already_stamped, "some-task"})

      conn = deliver("pull_request", @merged_pr)

      assert %{"ok" => true, "reconciled" => "already_stamped"} = json_response(conn, 200)
    end

    test "an unknown-task outcome answers 202 (accepted no-op, never a retry)" do
      stub_merge_events({:unknown_task, "ghost"})

      conn = deliver("pull_request", @merged_pr)

      assert %{"ok" => true, "ignored" => "unknown_task"} = json_response(conn, 202)
    end

    test "a non-merge close (:ignored) answers 202 without stamping" do
      stub_merge_events(:ignored)

      conn = deliver("pull_request", @merged_pr)

      assert %{"ok" => true, "ignored" => "ignored"} = json_response(conn, 202)
      assert_received {:merge_events_called, _payload, _opts}
    end

    test "a genuine ledger write failure answers 500 (retryable, replay-safe)" do
      stub_merge_events({:error, :stale_rev})

      conn = deliver("pull_request", @merged_pr)

      assert %{"error" => %{"code" => "merge_reconcile_failed"}} = json_response(conn, 500)
    end
  end
end
