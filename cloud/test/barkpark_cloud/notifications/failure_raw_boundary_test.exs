defmodule BarkparkCloud.Notifications.FailureRawBoundaryTest do
  @moduledoc """
  deploy-reliability W20 S4 (charter D354) — the ALERT EMAIL's raw provider
  capture obeys its own module's raw-log rule: `strip_ansi/1` BEFORE `scrub/1`.

  `failure_copy.ex:184-187` rules that any path rendering a RAW capture without
  classifying it must be `strip_ansi() |> scrub()`, and states the measurement
  behind that order: 2000/2000 leaked under `scrub |> strip_ansi` and 0/2000
  under `strip_ansi |> scrub`. `event_email.ex` had TWO such paths calling a bare
  `FailureCopy.scrub/1` on the verbatim provider bytes — `detail/1` and
  `cause_then_capture/1` — so a colourised `api_key=` shipped to an operator's
  inbox in cleartext.

  ## Why the leak works

  `scrub/1`'s key clause opens with `(?<![A-Za-z0-9])`. In
  `\\e[31mapi_key=<value>` the byte immediately left of `api_key` is the `m` that
  terminates the CSI run — an alphanumeric — so the lookbehind fails and the
  clause never fires. Strip the escape first and the same clause matches.

  ## The fixture shape is load-bearing; do not "simplify" it

  The secret must be

    * NON-PREFIXED (`api_key=<value>`): a `bppat_`/`sk-`/`ghp_` token is caught
      by the provider-prefix clause under BOTH orders, which is exactly how a
      test can be vacuously green at this seam;
    * SUB-32-CHAR: at 32+ mixed-case alnum the bare-entropy clause catches it
      regardless of order;
    * spelled so the key clause's lookbehind is not ALREADY satisfied — a
      `BARKPARK_TOKEN=` closes either way, because `_` is not alphanumeric;
    * COLOURISED with the escape run BEFORE the key — an escape after the `=` is
      order-independent too.

  Change any one of those four and this file goes green against the broken code.

  ## Both call sites, and the non-secret text

  Every case also asserts the SURROUNDING non-secret capture text is still
  present, so the fix cannot pass by deleting or truncating content —
  `failure_copy.ex:20`/`:41`/`:136` rule that the honest internal reason is
  deliberately preserved in full for a reader forwarding it to support.

  `:agent_unreachable` is the `detail/1` site. `:provision_failed` and
  `:deployment_failed` are the `cause_then_capture/1` site, covering BOTH of its
  arms: the `^capture` EQUAL-arm (an unclassified reason, where the capture
  stands alone) and the cause arm (a classified reason, where the human class
  leads and the capture is kept below it).

  MUTATION: revert either site to a bare `FailureCopy.scrub/1` and the
  corresponding `refute … =~ @secret` reds.

  PRIOR ART: PR #10019 carries the same fix and its own
  `failure_raw_boundary_test.exs`, at repo root scope (the JSON route, the chat
  render and this email). It is 113 commits behind with 2 conflicts across 6
  files and 3 red checks, so charter D355 rules it RE-CUT rather than rebased.
  This file is the email-only re-cut; it does not touch `failure_copy.ex`, so it
  composes `strip_ansi |> scrub` at the call site instead of through #10019's
  proposed `FailureCopy.raw/1` helper.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.EventEmail

  # 24 chars, mixed case + digits, no separator, no provider prefix: under the
  # 32-char entropy floor, so ONLY the key clause can redact it — and only if the
  # escape run is gone by the time that clause runs.
  @secret "Qp9vR4tZ7wN1cB6yH3sD5fG0"

  # A verbatim-shaped build capture: the producer's own prose, then a PTY colour
  # run, then the credential. This is what the control plane stores RAW.
  @unclassified "graph corpus fetch failed: 403 \e[31mapi_key=#{@secret}\e[0m"

  # The same colourised leak inside a reason `FailureCopy.classify/1` DOES
  # recognize ("no build source"), so `cause_then_capture/1` takes its CAUSE arm.
  @classified "no build source for site: \e[31mapi_key=#{@secret}\e[0m"

  # No Repo, no sandbox: `build/4` only reads From fields off this struct.
  defp settings, do: %EmailSettings{}

  defp body(event, detail) do
    EventEmail.build(
      settings(),
      event,
      %{"name" => "acme", "detail" => detail},
      "ops@example.com"
    ).text_body
  end

  describe "detail/1 — the plain raw-capture site (:agent_unreachable)" do
    test "a colourised, non-prefixed, sub-32-char secret is REDACTED in the email body" do
      body = body(:agent_unreachable, @unclassified)

      # THE ASSERTION THIS SITE EXISTS FOR. Revert `detail/1` to a bare
      # `FailureCopy.scrub(d)` and this line reds.
      refute body =~ @secret

      # RAW OF THE REWRITE, NOT RAW OF THE SECRETS: the producer's own words —
      # what makes the failure actionable — still reach the reader, and the key
      # is still named so the reader knows WHICH credential to rotate.
      assert body =~ "graph corpus fetch failed: 403"
      assert body =~ "api_key=[redacted]"

      # …and no escape byte reaches the inbox to render as mojibake.
      refute String.contains?(body, "\e")
    end
  end

  describe "cause_then_capture/1 — the cause+capture site (:provision_failed, :deployment_failed)" do
    test "EQUAL-arm (unclassified): the capture stands alone, and the secret is REDACTED" do
      body = body(:provision_failed, @unclassified)

      # Revert `cause_then_capture/1`'s capture to a bare `FailureCopy.scrub(d)`
      # and this line reds.
      refute body =~ @secret

      assert body =~ "graph corpus fetch failed: 403"
      assert body =~ "api_key=[redacted]"
      refute String.contains?(body, "\e")

      # The `^capture` EQUAL-arm still fires: an unclassified reason humanizes to
      # the capture itself, so the paragraph is printed ONCE and the capture
      # heading never appears. If the equal-arm broke, `humanize/1`'s leaky
      # pass-through would ALSO print above the clean capture.
      refute body =~ "What the provider reported:"
      assert length(String.split(body, "api_key=[redacted]")) == 2
    end

    test "CAUSE arm (classified): the human class leads, the capture is kept in full below it, secret REDACTED" do
      body = body(:deployment_failed, @classified)

      refute body =~ @secret

      # The class leads…
      assert body =~ "This site has no build source yet. Connect a repo or run bp deploy."
      # …the heading separates it…
      assert body =~ "What the provider reported:"
      # …and the honest capture is preserved below, unreordered and untruncated.
      assert body =~ "no build source for site: api_key=[redacted]"
      refute String.contains?(body, "\e")
    end

    test "the same colourised leak is redacted on :provision_failed's classified arm too" do
      body = body(:provision_failed, @classified)

      refute body =~ @secret
      assert body =~ "What the provider reported:"
      assert body =~ "no build source for site: api_key=[redacted]"
    end
  end

  describe "the fixture can still lose" do
    # If this ever reds, the fixture stopped being a leak shape and every
    # `refute` above went vacuous. It asserts the WRONG order on the raw string,
    # not on any call site — the call-site assertions are above.
    test "the bare scrub (the shipped order) really does leak this fixture" do
      leaked =
        @unclassified
        |> BarkparkCloud.FailureCopy.scrub()
        |> BarkparkCloud.FailureCopy.strip_ansi()

      assert leaked =~ @secret
    end
  end
end
