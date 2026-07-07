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
    on_exit(fn -> Application.delete_env(:barkpark, :github_webhook_intake_fun) end)
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

    test "non-opened action (:ignored) answers 202 no-op" do
      stub_intake(:ignored)

      conn = deliver("issues", Map.put(@issue_opened, "action", "closed"))

      assert %{"ok" => true, "ignored" => "action"} = json_response(conn, 202)
      assert_received {:intake_called, _payload, _opts}
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
end
