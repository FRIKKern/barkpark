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
end
