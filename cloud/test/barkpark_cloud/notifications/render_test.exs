defmodule BarkparkCloud.Notifications.RenderTest do
  @moduledoc """
  wave 29 — the CHAT arm of a failure alert tells the same story the inbox does.

  `dispatch_event/3` builds the alert email and enqueues the chat jobs from ONE
  payload, but `render.ex` never read `:detail`, so charter D310
  (`provision_failed`) and D333 / wave 28 S6 (`deployment_failed`) both landed on
  the email arm alone. Driven at origin/main `c012e5a7c`, one failure told the
  same person two stories in the same minute:

      EMAIL deployment_failed -> "A deployment for acme failed.\\n\\nThe build
        didn't finish after several attempts and was stopped. Deploy again to
        retry.\\n\\nWhat the provider reported:\\n\\nexceeded max deploy claim
        attempts (stale builder lease)"
      CHAT  deployment_failed -> "A deployment for acme failed."   <- and nothing else
      EMAIL provision_failed  -> "acme failed to provision.\\n\\nHetzner ran out of
        server capacity for this size. Try again shortly or contact support." + capture
      CHAT  provision_failed  -> "Provisioning failed for acme."   <- cause-free too

  BEFORE THIS FILE THE CHAT BODY HAD NO GUARD AT ALL: `git grep 'Render.render'
  -- cloud/test` returned nothing, and `chat_test.exs` pins only the ENQUEUE
  shape (worker, channel_type, event) — green with the defect fully present.

  THE SCRUB BOUNDARY IS THE POINT, not a footnote. The email keeps the raw
  provider capture below the class for a reader forwarding it to support; chat
  must NOT, because the same bytes are already sitting unscrubbed in
  `oban_jobs.args` and rendering them would turn a storage problem into egress
  across five third-party hosts. The secret-shaped assertions below are what
  hold that: they would fail the moment the raw `:detail` reached a body.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.FailureCopy
  alias BarkparkCloud.Notifications.Channels
  alias BarkparkCloud.Notifications.Render

  # The reaper's own stale-lease prose and the provision path's fallback-ladder
  # aggregate — the two real producer corpora behind these events.
  @deploy_reason "exceeded max deploy claim attempts (stale builder lease)"
  @provision_reason "CreateWithFallback: cx22: SERVER_LIMIT_EXCEEDED; cx32: resource_unavailable"

  # Pushover's `message` field caps at 1024 characters. It is the smallest
  # envelope of the five and therefore the one that decides the clamp.
  @pushover_message_limit 1024

  # A real `deployments` primary key shape — the handle `GET
  # /v1/sites/:id/deployments/:dep_id` takes.
  @deployment_id "d5f0c0de-1111-4222-8333-abcdefabcdef"

  describe "the failure events carry their cause" do
    test "deployment_failed renders the class the dashboard and the inbox both render" do
      {title, body, severity} =
        Render.render("deployment_failed", %{"site" => "acme", "detail" => @deploy_reason})

      assert title == "Deployment failed"
      assert severity == :error
      assert body =~ "A deployment for acme failed."

      assert body =~ "The build didn't finish after several attempts and was stopped."
      assert body == "A deployment for acme failed.\n\n#{FailureCopy.humanize(@deploy_reason)}"
    end

    # wave 15 S4 — the equality above still holds for an identity-free payload
    # (the legacy shape), and this is the same assertion for the shape the
    # producer sends today: the identity paragraph sits between the lead sentence
    # and the cause. Equality, not containment, so an extra body line reds here.
    test "deployment_failed names WHICH deployment, above the cause" do
      {_title, body, :error} =
        Render.render("deployment_failed", %{
          "site" => "acme",
          "deployment_id" => @deployment_id,
          "stage" => "BUILD",
          "git_ref" => "refs/heads/main",
          "detail" => @deploy_reason
        })

      assert body ==
               "A deployment for acme failed.\n\n" <>
                 "Deployment #{@deployment_id} · stage BUILD · git_ref refs/heads/main\n\n" <>
                 FailureCopy.humanize(@deploy_reason)
    end

    test "the identity degrades to what the producer actually held — no filler" do
      # The reaper's fan-out carries the id its `select:` already named, and
      # nothing else. A missing stage/code identity is simply absent.
      assert Render.render("deployment_failed", %{
               "site" => "acme",
               "deployment_id" => @deployment_id
             }) ==
               {"Deployment failed",
                "A deployment for acme failed.\n\nDeployment #{@deployment_id}", :error}

      # A static build has no git_ref: the content revision is the code identity,
      # under its own column name.
      {_t, body, _s} =
        Render.render("deployment_failed", %{
          "site" => "acme",
          "deployment_id" => @deployment_id,
          "content_rev" => "rev-9"
        })

      assert body ==
               "A deployment for acme failed.\n\nDeployment #{@deployment_id} · content_rev rev-9"
    end

    test "the identity carries no duration and no link" do
      {_t, body, _s} =
        Render.render("deployment_failed", %{
          "site" => "acme",
          "deployment_id" => @deployment_id,
          "stage" => "BUILD",
          "git_ref" => "main",
          "detail" => @deploy_reason
        })

      # `deployments` has no started_at/finished_at and `became_live_at` is NULL
      # on every failed row — a build time here could only be fabricated.
      for word <- ~w(duration took elapsed lasted) do
        refute body =~ word
      end

      # No link: the notifications layer has no console base URL, and the
      # deployment id is the handle instead.
      refute body =~ "http"
      # There is no commit-sha column; the code identity keeps its real name.
      refute body =~ "commit"
    end

    test "provision_failed carries its cause too — the D310 fix reached only the email arm" do
      {title, body, severity} =
        Render.render("provision_failed", %{"site" => "acme", "detail" => @provision_reason})

      assert title == "Provisioning failed"
      assert severity == :error
      assert body =~ "Provisioning failed for acme."
      # PINNED BY DERIVATION, NOT BY LITERAL (review, cross-slice). The capacity
      # arm's sentence is being narrowed in the same wave — `humanize/1` is the
      # authority on its exact bytes, and quoting them here would red this file
      # the moment the sibling slice lands. What this leg owes is that the CLASS
      # reached chat and the raw provider jargon did not; both survive any
      # rewording of the arm.
      assert body =~ "capacity"
      refute body =~ "SERVER_LIMIT_EXCEEDED"
      refute body =~ "CreateWithFallback"
      assert body == "Provisioning failed for acme.\n\n#{FailureCopy.humanize(@provision_reason)}"
    end

    test "the atom-keyed payload reads the same as the Oban-args string-keyed one" do
      assert Render.render("deployment_failed", %{site: "acme", detail: @deploy_reason}) ==
               Render.render("deployment_failed", %{"site" => "acme", "detail" => @deploy_reason})
    end

    test "a detail-free payload keeps the bare line — no dangling blank paragraph" do
      assert {_, "A deployment for acme failed.", :error} =
               Render.render("deployment_failed", %{"site" => "acme"})

      assert {_, "Provisioning failed for acme.", :error} =
               Render.render("provision_failed", %{"site" => "acme", "detail" => ""})
    end

    test "the non-failure events are untouched by the cause seam" do
      assert {_, "acme finished provisioning and is live.", :info} =
               Render.render("provision_succeeded", %{"site" => "acme", "detail" => "ignored"})

      assert {_, "acme stopped responding to health checks.", :warning} =
               Render.render("agent_unreachable", %{"site" => "acme"})
    end
  end

  describe "the cause is humanized, never raw — the chat egress boundary" do
    test "a secret-shaped detail never reaches the body verbatim" do
      secret = "hcloud_A1b2C3d4E5f6G7h8"
      raw = "provisioning failed: api_key=#{secret} rejected by upstream"

      for event <- ["deployment_failed", "provision_failed"] do
        {_title, body, _severity} = Render.render(event, %{"site" => "acme", "detail" => raw})

        refute body =~ secret
        refute body =~ raw
        assert body =~ "[redacted]"
      end
    end

    test "a bearer credential in an unclassified reason is redacted on every channel shaper" do
      raw = "Authorization: Bearer sk-live-A1b2C3d4E5f6G7h8i9"
      payload = %{"site" => "acme", "detail" => raw}

      {:ok, _url, discord, _h} =
        Channels.Discord.shape(%{"url" => "https://x.test/h"}, "deployment_failed", payload)

      {:ok, _url, slack, _h} =
        Channels.Slack.shape(%{"url" => "https://x.test/h"}, "deployment_failed", payload)

      {:ok, _url, telegram, _h} =
        Channels.Telegram.shape(
          %{"token" => "bot-token", "chat_id" => "42"},
          "deployment_failed",
          payload
        )

      {:ok, _url, pushover, _h} =
        Channels.Pushover.shape(
          %{"user_key" => "u", "api_token" => "t"},
          "deployment_failed",
          payload
        )

      # Pushover is form-encoded, the other three are JSON — decode the form so
      # every arm is compared as the text a person will actually read.
      pushover = URI.decode_query(IO.iodata_to_binary(pushover))["message"]

      for wire <- [discord, slack, telegram, pushover] do
        wire = IO.iodata_to_binary(wire)
        refute wire =~ "sk-live-A1b2C3d4E5f6G7h8i9"
        assert wire =~ "[redacted]"
      end
    end

    test "the raw provider capture is NOT appended the way the email appends it" do
      {_title, body, _severity} =
        Render.render("deployment_failed", %{"site" => "acme", "detail" => @deploy_reason})

      # The email's capture heading and verbatim bytes stay on the email.
      refute body =~ "What the provider reported:"
      refute body =~ @deploy_reason
    end
  end

  describe "every channel envelope still holds the longer body" do
    setup do
      %{payload: %{"site" => "acme", "detail" => @deploy_reason}}
    end

    test "discord embeds a description well inside its 4096 limit", %{payload: payload} do
      {:ok, url, json, headers} =
        Channels.Discord.shape(%{"url" => "https://x.test/h"}, "deployment_failed", payload)

      assert url == "https://x.test/h"
      assert {"content-type", "application/json"} in headers
      %{"embeds" => [embed]} = Jason.decode!(json)
      assert embed["description"] =~ "The build didn't finish"
      assert String.length(embed["description"]) <= 4096
    end

    test "slack fills both the fallback text and the section block", %{payload: payload} do
      {:ok, _url, json, _headers} =
        Channels.Slack.shape(%{"url" => "https://x.test/h"}, "deployment_failed", payload)

      decoded = Jason.decode!(json)
      assert decoded["text"] =~ "The build didn't finish"
      [_header, section] = decoded["blocks"]
      assert section["text"]["text"] =~ "The build didn't finish"
      assert String.length(section["text"]["text"]) <= 3000
    end

    test "telegram sends one message under its 4096 limit", %{payload: payload} do
      {:ok, url, json, _headers} =
        Channels.Telegram.shape(
          %{"token" => "bot-token", "chat_id" => "42"},
          "deployment_failed",
          payload
        )

      assert url =~ "/botbot-token/sendMessage"
      text = Jason.decode!(json)["text"]
      assert text =~ "The build didn't finish"
      assert String.length(text) <= 4096
    end

    test "pushover — the smallest envelope — stays inside its hard 1024 cap", %{payload: payload} do
      {:ok, _url, form, _headers} =
        Channels.Pushover.shape(
          %{"user_key" => "u", "api_token" => "t"},
          "deployment_failed",
          payload
        )

      %{"message" => message} = URI.decode_query(IO.iodata_to_binary(form))
      assert message =~ "The build didn't finish"
      assert String.length(message) <= @pushover_message_limit
    end

    test "an unbounded unclassified reason is clamped so pushover cannot reject the POST" do
      # A fallback-ladder aggregate that classifies to nothing is the realistic
      # worst case: it passes through as itself, scrubbed.
      huge = "candidate failed: " <> String.duplicate("some provider prose. ", 400)

      {_t, body, _s} = Render.render("provision_failed", %{"site" => "acme", "detail" => huge})

      assert String.ends_with?(body, "…")
      assert String.length(body) < @pushover_message_limit

      {:ok, _url, form, _headers} =
        Channels.Pushover.shape(
          %{"user_key" => "u", "api_token" => "t"},
          "provision_failed",
          %{"site" => "acme", "detail" => huge}
        )

      %{"message" => message} = URI.decode_query(IO.iodata_to_binary(form))
      assert String.length(message) <= @pushover_message_limit
    end

    test "the generic webhook carries the same message field" do
      # A public IP LITERAL, not a hostname: `Webhook.shape/4` re-runs the SSRF
      # check at send time, and a name would make this test depend on DNS.
      {:ok, _url, json, _headers} =
        Channels.Webhook.shape(
          %{"url" => "https://203.0.113.10/hook"},
          "deployment_failed",
          %{"site" => "acme", "detail" => @deploy_reason},
          team_id: "t-1"
        )

      decoded = Jason.decode!(json)
      assert decoded["message"] =~ "The build didn't finish"
      assert decoded["title"] == "Deployment failed"
    end
  end

  # ── cch-w32-s1: the trial teardown gets a NAMED arm ────────────────────────
  #
  # `trial_expiring` had no arm. Routed to chat it would have fallen to the
  # catch-all — "Event: trial_expiring for acme." at `:info`, which Discord
  # renders GREEN — for a message whose subject is an instance being torn down.
  describe "trial_expiring is rendered, not fallen through" do
    test "days=3 reads as a plural window at :warning" do
      {title, body, severity} =
        Render.render("trial_expiring", %{"name" => "acme", "days" => 3})

      assert title == "Trial ending"
      assert severity == :warning

      assert body ==
               "Your free trial ends in 3 days — acme is torn down automatically when it ends."
    end

    test "days=1 reads as a singular day" do
      {_title, body, severity} =
        Render.render("trial_expiring", %{"name" => "acme", "days" => 1})

      assert severity == :warning
      assert body =~ "ends in 1 day —"
      refute body =~ "1 days"
    end

    test "it is NOT the generic fallback (which would ship :info — Discord green)" do
      {title, body, severity} =
        Render.render("trial_expiring", %{"name" => "acme", "days" => 3})

      refute title == "Barkpark Cloud"
      refute body =~ "Event: trial_expiring"
      refute severity == :info
    end

    test "the body is built from :days ALONE — never :detail, never through humanize/1" do
      # The producer supplies BOTH. `detail` is control-plane-authored prose, and
      # `FailureCopy.humanize/1` is `classify() |> scrub()` — a failure taxonomy
      # plus a credential redactor. There is nothing to classify and nothing to
      # scrub here, and a future `@scrub_rules` pattern would silently rewrite
      # customer copy. So the arm must ignore `detail` entirely.
      detail =
        "Your Barkpark free trial ends in 3 days. Upgrade to keep your instance running — " <>
          "it's torn down automatically when the trial ends."

      {_t, with_detail, _s} =
        Render.render("trial_expiring", %{"name" => "acme", "days" => 3, "detail" => detail})

      {_t, without_detail, _s} =
        Render.render("trial_expiring", %{"name" => "acme", "days" => 3})

      assert with_detail == without_detail,
             "the presence of :detail must not change one byte of the trial body"

      refute with_detail =~ "Upgrade to keep your instance running"
    end

    test "a missing or nonsense day count degrades to a readable window, never 'in  days'" do
      for payload <- [
            %{"name" => "acme"},
            %{"name" => "acme", "days" => nil},
            %{"name" => "acme", "days" => "soonish"}
          ] do
        {_t, body, severity} = Render.render("trial_expiring", payload)
        assert body == "Your free trial ends soon — acme is torn down automatically when it ends."
        assert severity == :warning
      end
    end

    test "atom keys work too — the payload is an Oban args map on one path and a struct-ish map on the other" do
      {_t, body, _s} = Render.render("trial_expiring", %{name: "acme", days: 2})
      assert body =~ "in 2 days"
    end
  end

  # ── cch-w52-bl: the TEARDOWN itself gets its own arm ───────────────────────
  #
  # `trial_expiring` above is the ADVANCE notice. The teardown that follows it
  # dispatched nothing at all: the measured run over a closed trial window was
  # `%{expired: 1, teardowns: 1}` with `delivery_rows_any_status = 0`. This arm
  # is the missing half, and it is a DIFFERENT fact — past tense, and it names
  # the instances, because "your trial ended" without the names leaves a team
  # guessing which of its boxes went.
  describe "trial_expired names what was torn down" do
    test "one instance reads in the singular, at :warning" do
      {title, body, severity} =
        Render.render("trial_expired", %{"name" => "acme", "instances" => ["acme-prod"]})

      assert title == "Trial ended"
      assert severity == :warning

      assert body ==
               "Your free trial has ended and acme-prod has been torn down. " <>
                 "Subscribe to a paid plan to run Barkpark again."
    end

    test "two and three instances read as a list, with the verb agreeing" do
      {_t, two, _s} =
        Render.render("trial_expired", %{"instances" => ["acme-prod", "acme-staging"]})

      assert two =~ "acme-prod and acme-staging have been torn down"
      refute two =~ "has been torn down"

      {_t, three, _s} =
        Render.render("trial_expired", %{"instances" => ["a", "b", "c"]})

      assert three =~ "a, b and c have been torn down"
    end

    test "it is NOT the generic fallback (which would ship :info — Discord green)" do
      # A teardown report arriving coloured like a success is the exact failure
      # the wave-32 census exists to foreclose, and this event is the worst
      # possible candidate for it: the boxes are already gone when it fires.
      {title, body, severity} =
        Render.render("trial_expired", %{"instances" => ["acme-prod"]})

      refute title == "Barkpark Cloud"
      refute body =~ "Event: trial_expired"
      refute severity == :info
    end

    test "the copy is PAST tense — it reports, it never warns" do
      {_t, body, _s} = Render.render("trial_expired", %{"instances" => ["acme-prod"]})

      refute body =~ "will be"
      refute body =~ "is torn down"
      refute body =~ "ends in"
    end

    test "a payload with no usable names degrades, never to an empty subject" do
      for payload <- [
            %{"name" => "acme"},
            %{"name" => "acme", "instances" => []},
            %{"name" => "acme", "instances" => nil},
            %{"name" => "acme", "instances" => ["", nil]}
          ] do
        {_t, body, severity} = Render.render("trial_expired", payload)
        assert body =~ "your Barkpark instances have been torn down"
        assert severity == :warning
      end
    end

    test "atom keys work too — the chat rail reads an Oban args map, the email rail a struct-ish one" do
      {_t, body, _s} = Render.render("trial_expired", %{instances: ["acme-prod"]})
      assert body =~ "acme-prod has been torn down"
    end
  end

  # ── cch-w32-s1: the test message discloses a muted team ────────────────────
  #
  # `send_test_chat/2` deliberately fires while `alerts_enabled` is false — it is
  # a TRANSPORT probe, and refusing would destroy the only instrument separating
  # "my webhook URL is wrong" from "I muted alerts three weeks ago". So the mute
  # travels with the message instead of blocking it.
  describe "the test event tells the truth about the master switch" do
    test "an unmuted team gets the plain confirmation, unchanged" do
      {title, body, severity} = Render.render("test", %{})

      assert title == "Test notification"
      assert severity == :info

      assert body ==
               "This is a test from Barkpark Cloud. If you can read this, the channel works."
    end

    test "a muted team is told the channel works AND that nothing real will arrive" do
      {title, body, severity} = Render.render("test", %{"alerts_muted" => true})

      assert title == "Test notification"
      assert severity == :warning
      assert body =~ "The channel works"
      assert body =~ "alerts are currently OFF for this team"
      assert body =~ "no real notification will be delivered"

      refute body =~ "If you can read this, the channel works.",
             "the unqualified sentence is exactly the yes this slice stopped answering"
    end

    test "the flag is read strictly — false, absent and a stray string all mean NOT muted" do
      for payload <- [%{}, %{"alerts_muted" => false}, %{"alerts_muted" => "true"}] do
        {_t, body, severity} = Render.render("test", payload)
        assert severity == :info
        assert body =~ "If you can read this"
      end

      {_t, _b, severity} = Render.render("test", %{alerts_muted: true})
      assert severity == :warning, "the atom-keyed payload is the in-process path"
    end
  end
end
