defmodule BarkparkCloud.FailureRawBoundaryTest do
  @moduledoc """
  THE TEST THAT CAN LOSE — deploy-reliability W8 S6.

  A raw failure capture reaches a person through three doors: the deployments
  JSON (`failure_reason_raw`), the alert email's verbatim capture, and the chat
  render. Each one hand-rolled its own composition of `FailureCopy.scrub/1` and
  `FailureCopy.strip_ansi/1`, and the composition is NOT commutative:

      scrub |> strip_ansi  →  the secret survives, the escapes do not
      strip_ansi |> scrub  →  the secret is redacted

  The first order returns a field with no 0x1B bytes in it and the credential in
  cleartext. It LOOKS clean. That is what made it survive.

  ## Why this file exists, and why a unit test could not stand here

  Before it, 142 tests were green with `router.ex`'s pipe flipped EITHER WAY —
  nothing pinned the CALL SITE's order in either direction, and a unit test over
  `scrub`/`strip_ansi` structurally cannot tell a fixed call site from a broken
  one. The one test that DID stand at the real boundary
  (`deploy_ledger_test.exs`, "a RAW reason that is scrubbed AND ANSI-free") used
  a `Bearer sk-live-…` secret — a shape the provider-prefix clause catches under
  BOTH orders — so it was vacuously green at the exact seam this epic exists to
  fix.

  ## The fixture shape is load-bearing; do not "simplify" it

  The secret MUST be:

    * NON-PREFIXED (`api_key=<value>`) — a `bppat_`/`sk-`/`ghp_` token is caught
      by the provider-prefix clause, which matches the token itself, under both
      orders;
    * SUB-32-CHAR — at 32+ mixed-case alnum the bare-entropy clause catches it
      regardless of order (measured: 2000/2000 leaked at 16-31 chars, 2/2000 at
      32-48);
    * spelled with a character the key clause's `(?<![A-Za-z0-9])` lookbehind
      does NOT already satisfy — a `BARKPARK_TOKEN=` closes either way, because
      the `_` is not alphanumeric;
    * COLOURISED with the escape run BEFORE the key — an escape after the `=` is
      order-independent too.

  Change any one of those four and this test goes green against the broken code.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, FailureCopy, Registry, Repo}
  alias BarkparkCloud.Notifications.{EmailSettings, EventEmail}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # 24 chars, mixed case + digits, no separator: under the 32-char entropy floor
  # and carrying no provider prefix, so ONLY the key clause can redact it — and
  # only if the escape run is gone by the time that clause runs.
  @secret "Qp9vR4tZ7wN1cB6yH3sD5fG0"

  # A verbatim-shaped build capture: the producer's own prefix, then a PTY colour
  # run, then the credential. This is the string the control plane stores RAW.
  @colourised_reason "graph corpus fetch failed: 403 \e[31mapi_key=#{@secret}\e[0m"

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp site_fixture do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    {:ok, token} = Accounts.create_user_session_token(user)
    %{site: site, token: token}
  end

  # Inserted as a STRUCT: `Deployment.changeset/2` forbids casting `status`
  # (`transition_changeset/2` is the sole status mutator), mirroring
  # `deploy_ledger_test.exs`.
  defp failed_deployment!(site, reason) do
    now = DateTime.utc_now()

    Repo.insert!(%Deployment{
      site_id: site.id,
      status: "failed",
      environment: "production",
      stage: "BUILD",
      failure_reason: reason,
      inserted_at: now,
      updated_at: now
    })
  end

  defp get_deployments(site, token) do
    conn(:get, "/v1/sites/#{site.id}/deployments")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  ## ── 1. The JSON route: the door the console reads ────────────────────────

  describe "GET /v1/sites/:id/deployments — the raw capture at the real boundary" do
    setup do: site_fixture()

    test "a colourised, non-prefixed, sub-32-char secret comes back REDACTED", %{
      site: site,
      token: token
    } do
      failed_deployment!(site, @colourised_reason)

      conn = get_deployments(site, token)
      assert conn.status == 200
      [row] = Jason.decode!(conn.resp_body)["deployments"]

      raw = row["failure_reason_raw"]

      # THE ASSERTION THIS FILE EXISTS FOR. Revert `router.ex`'s
      # `FailureCopy.raw/1` to `scrub |> strip_ansi` and this line — and only
      # this line, of 142 — reds.
      refute raw =~ @secret

      # RAW OF THE REWRITE, NOT RAW OF THE SECRETS: the producer's own words,
      # which are what make the failure actionable, still reach the reader.
      assert raw == "graph corpus fetch failed: 403 api_key=[redacted]"

      # …and no escape byte reaches the screen, in either field.
      refute String.contains?(raw, "\e")
      refute String.contains?(row["failure_reason"], "\e")

      # The neighbouring humanized field must not leak it either: this reason
      # classifies into no bucket, so it rides `humanize/1`'s pass-through arm —
      # a raw-log path wearing a different name.
      refute row["failure_reason"] =~ @secret
    end

    test "the stored row keeps the raw bytes — the redaction is a DISPLAY boundary", %{
      site: site,
      token: token
    } do
      d = failed_deployment!(site, @colourised_reason)

      # Ops recovery via the DB and the logs is unaffected by any of this.
      stored = Repo.get!(Deployment, d.id).failure_reason
      assert stored == @colourised_reason
      assert stored =~ @secret
      assert String.contains?(stored, "\e")

      # Only the serialization boundary redacts.
      [row] =
        get_deployments(site, token)
        |> then(&Jason.decode!(&1.resp_body))
        |> Map.get("deployments")

      refute row["failure_reason_raw"] =~ @secret
    end

    test "a Bearer secret redacts too — the shape that could NOT catch this bug", %{
      site: site,
      token: token
    } do
      # Kept deliberately, as the control: it was green before W8 S6 and is green
      # after, which is exactly why the fixture above had to be different.
      failed_deployment!(site, "ssh: remote said Authorization: Bearer sk-live-AbC123dEf456GhI")

      [row] =
        get_deployments(site, token)
        |> then(&Jason.decode!(&1.resp_body))
        |> Map.get("deployments")

      refute row["failure_reason_raw"] =~ "sk-live-AbC123dEf456GhI"
    end
  end

  ## ── 2. The inbox: the door that leaves our boundary for good ─────────────

  describe "EventEmail.build/4 — the capture a customer keeps forever" do
    test "deployment_failed's verbatim capture carries neither the secret nor an ESC byte" do
      email =
        EventEmail.build(
          %EmailSettings{},
          :deployment_failed,
          %{name: "acme", detail: @colourised_reason},
          "owner@example.com"
        )

      refute email.text_body =~ @secret
      refute String.contains?(email.text_body, "\e")
      assert email.text_body =~ "api_key=[redacted]"
      # The producer's honest words survive — D310's "both, not either".
      assert email.text_body =~ "graph corpus fetch failed: 403"
    end

    test "the generic detail/1 arm is guarded too — every event, not just the failures" do
      email =
        EventEmail.build(
          %EmailSettings{},
          :agent_unreachable,
          %{name: "acme", detail: @colourised_reason},
          "owner@example.com"
        )

      refute email.text_body =~ @secret
      refute String.contains?(email.text_body, "\e")
    end
  end

  ## ── 3. The named boundary itself ─────────────────────────────────────────

  describe "FailureCopy.raw/1 — one spelling, so no call site can hand-roll it" do
    test "it is strip_ansi |> scrub, and the flipped composition still leaks" do
      assert FailureCopy.raw(@colourised_reason) ==
               @colourised_reason |> FailureCopy.strip_ansi() |> FailureCopy.scrub()

      refute FailureCopy.raw(@colourised_reason) =~ @secret

      # The order is the whole bug, restated where it is impossible to miss.
      assert @colourised_reason |> FailureCopy.scrub() |> FailureCopy.strip_ansi() =~ @secret
    end

    test "it is idempotent and no-ops on non-binaries" do
      once = FailureCopy.raw(@colourised_reason)
      assert FailureCopy.raw(once) == once
      assert FailureCopy.raw(nil) == nil
      assert FailureCopy.raw(%{a: 1}) == %{a: 1}
    end
  end
end
