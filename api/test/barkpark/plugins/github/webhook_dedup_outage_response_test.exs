defmodule Barkpark.Plugins.Github.WebhookDedupOutageResponseTest do
  @moduledoc """
  WHERE `{:error, {:dedup_unavailable, _}}` LANDS ON THE WIRE
  (jpf-bl-intake-dedup-clause-test, the controller half).

  `Intake` forwards a dedup outage as `{:error, {:dedup_unavailable, reason}}`
  (pinned by `intake_dedup_outage_test.exs`) and `GithubWebhookController`
  answers it with a 500 `intake_failed`. A 2xx there would DROP the outsider's
  issue: a 2xx is final, GitHub keeps no failure to redeliver, and the intake
  log would record a policy refusal that never happened.

  ## Why the existing assertion did not already cover this

  `github_webhook_controller_test.exs` has "a genuine intake failure
  ({:error, _}) answers 5xx", which asserts
  `%{"error" => %{"code" => "intake_failed"}} = json_response(conn, 500)`. It
  drives the seam with `{:error, :db_unavailable}`. That pins the catch-all's
  STATUS and CODE, and a different error reaching the same mapping satisfies it
  identically — it says nothing about which arm a `{:dedup_unavailable, _}`
  takes. Measured at `origin/main` 06120ffc8 over 609 tests
  (`test/barkpark/plugins/github/`, the controller test and all seven
  `dedup_unavailable` test files):

  | mutation to `api/lib` | before this file |
  |---|---|
  | rename the catch-all's `code: "intake_failed"` | 25 tests, **1 failure** — the generic mapping was already pinned |
  | add a `{:error, {:dedup_unavailable, _}}` → 202 arm ABOVE the catch-all | 609 tests, **0 failures** — the shape's routing was not |

  With this file, that 202 mutation reds: 518 tests, 1 failure, on
  "`{:error, {:dedup_unavailable, reason}}` → 500, never a 2xx".

  This file closes the second row, and its DISCRIMINATOR test stops the first
  one from being closed by the cheap wrong fix ("make every Intake outcome a
  500"): the deterministic lifecycle veto, the outage's look-alike neighbour in
  `Intake.birth/2`, must stay 2xx.

  ## The honest claim about a 500

  GitHub does not auto-redeliver a 5xx — redelivery is manual or
  API-triggered. The 500 is not self-healing. Its value is that it is LOUD AND
  FINDABLE: a failed delivery in the repo's webhook log, and an error line in
  ours. The 2xx alternative leaves no trace at either end.

  `async: false`: the Intake seam is `Application.put_env/3`, which is global.
  """

  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.GithubWebhookController

  setup do
    on_exit(fn -> Application.delete_env(:barkpark, :github_webhook_intake_fun) end)
    :ok
  end

  # The documented seam (`config :barkpark, :github_webhook_intake_fun`), driven
  # with the EXACT tuple `Intake` returns — so these tests pin where that SHAPE
  # lands, not merely that some error produces a 500.
  defp stub_intake(result) do
    test = self()

    Application.put_env(:barkpark, :github_webhook_intake_fun, fn payload, opts ->
      send(test, {:intake_called, payload, opts})
      result
    end)
  end

  defp deliver(params) do
    build_conn()
    |> put_req_header("x-github-event", "issues")
    |> GithubWebhookController.receive(params)
  end

  defp opened_payload(number) do
    %{
      "action" => "opened",
      "issue" => %{
        "number" => number,
        "title" => "Outsider found a bug",
        "body" => "Steps to reproduce: click the thing.",
        "user" => %{"login" => "outsider", "type" => "User"}
      },
      "sender" => %{"login" => "outsider", "type" => "User"},
      "repository" => %{"full_name" => "FRIKKern/barkpark"}
    }
  end

  describe "a dedup outage is answered 500 intake_failed" do
    test "{:error, {:dedup_unavailable, reason}} → 500, never a 2xx" do
      stub_intake(
        {:error,
         {:dedup_unavailable,
          "task dedup gate could not complete: the backlog scan did not finish"}}
      )

      conn = deliver(opened_payload(9403))

      assert %{"error" => %{"code" => "intake_failed"}} = json_response(conn, 500)
      assert_received {:intake_called, _payload, _opts}
    end

    test "DISCRIMINATOR: the adjacent deterministic veto is still answered 2xx" do
      # Without this, "answer every Intake outcome 500" would satisfy the test
      # above while breaking the door. `{:refused, :vetoed, _}` is the outage's
      # look-alike neighbour in `Intake.birth/2` — deterministic, so a
      # redelivery would only hit the same veto forever, so 2xx is correct.
      stub_intake({:refused, :vetoed, "gh-9404"})

      conn = deliver(opened_payload(9404))

      assert conn.status in 200..299
      assert_received {:intake_called, _payload, _opts}
    end
  end
end
