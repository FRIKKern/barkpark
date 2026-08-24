defmodule BarkparkWeb.AuthNotificationWithholdTest do
  @moduledoc """
  The controller half: a notification the request never reached is now
  distinguishable from one it deliberately skipped — WITHOUT weakening the
  anti-enumeration contract those skips exist to serve.

  The two halves of this suite pull in opposite directions on purpose. One says
  "the visible response must stay identical whatever happened"; the other says
  "the operator-visible record must differ". Both must hold at once, or the fix
  has either leaked account existence or achieved nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Accounts
  alias Barkpark.Accounts.NotificationWithhold
  alias Barkpark.Audit.Event
  alias Barkpark.Repo

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @password})
    u
  end

  defp withhold_events do
    Repo.all(
      from e in Event,
        where: e.category == "auth" and e.action == "notification_withheld",
        order_by: [asc: e.id]
    )
  end

  # ── The anti-enumeration contract must survive the fix ─────────────────────

  describe "the DELIBERATE skips still skip, and still say nothing to the caller" do
    test "request-reset: unknown address sends no email and returns the generic ok", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/request-reset", %{email: "ghost@example.com"})

      assert json_response(resp, 200) == %{"ok" => true}
      refute_receive {:email, _}, 200
    end

    test "request-magic-link: unknown address sends no email and returns the generic ok", %{
      conn: conn
    } do
      resp = post_json(conn, "/v1/auth/request-magic-link", %{email: "ghost@example.com"})

      assert json_response(resp, 200) == %{"ok" => true}
      refute_receive {:email, _}, 200
    end

    test "a known and an unknown address are byte-identical to the caller", %{conn: conn} do
      user("known@example.com")

      known = post_json(conn, "/v1/auth/request-reset", %{email: "known@example.com"})
      unknown = post_json(build_conn(), "/v1/auth/request-reset", %{email: "ghost@example.com"})

      assert known.status == unknown.status
      assert known.resp_body == unknown.resp_body
    end

    test "register with an already-taken address still returns the generic acceptance", %{
      conn: conn
    } do
      user("taken@example.com")

      resp =
        post_json(conn, "/v1/auth/register", %{email: "taken@example.com", password: @password})

      # Indistinguishable from a fresh signup — the existence oracle stays shut.
      assert resp.status == 201
    end
  end

  # ── The silence is no longer uniform ───────────────────────────────────────

  describe "a CONSENTED skip leaves no record — a probe cannot write to the log" do
    test "hammering request-magic-link with unknown addresses writes no withhold events", %{
      conn: _conn
    } do
      before = length(withhold_events())

      for n <- 1..10 do
        post_json(build_conn(), "/v1/auth/request-magic-link", %{email: "ghost#{n}@example.com"})
      end

      # Consented: there is nobody the notification was withheld FROM, so there
      # is no row to show anyone — and an attacker cannot amplify probes into
      # audit writes.
      assert length(withhold_events()) == before
    end

    test "the same is true for request-reset", %{conn: conn} do
      before = length(withhold_events())
      post_json(conn, "/v1/auth/request-reset", %{email: "ghost@example.com"})
      assert length(withhold_events()) == before
    end
  end

  describe "a REAL withhold from a REAL user IS recorded" do
    test "the operator can tell a broken notification from a deliberate skip", %{conn: conn} do
      u = user("real@example.com")
      before = length(withhold_events())

      # The consented case: same endpoint, same generic 200, no record.
      resp = post_json(conn, "/v1/auth/request-magic-link", %{email: "ghost@example.com"})
      assert json_response(resp, 200) == %{"ok" => true}
      assert length(withhold_events()) == before

      # The broken case: a REAL user whose notification could not be dispatched.
      # Driven through the funnel the controller branch now calls, because the
      # underlying failure ({:error, _} from the token mint) is a mid-flight race
      # that cannot be forced end-to-end through HTTP without fabricating a seam.
      assert {:ok, 1} =
               NotificationWithhold.record("magic_link", :dispatch_crashed,
                 user_id: u.id,
                 detail: "token_mint_failed"
               )

      events = withhold_events()
      assert length(events) == before + 1

      event = List.last(events)
      assert event.subject == "magic_link"
      assert event.actor_id == u.id
      assert event.metadata["reason"] == "dispatch_crashed"

      # AND the two cases are separable by query, which is the whole point.
      assert Enum.count(events, &(&1.metadata["reason"] == "dispatch_crashed")) >= 1
    end
  end

  # ── The controller wiring itself ───────────────────────────────────────────
  #
  # HONEST LABEL: these are STRUCTURAL pins, not behavioural ones, and the
  # distinction matters. The behavioural difference the controller change buys
  # shows up ONLY in the {:error, _} arm, and that arm is a mid-flight race (the
  # user row vanishing between the read and the token insert inside
  # build_login_token/1) that no HTTP request can trigger without fabricating a
  # seam. The funnel's behaviour is proved for real in
  # Barkpark.Accounts.NotificationWithholdTest; what these add is a tripwire so
  # the branch cannot silently regress to the catch-all it came from.

  describe "the magic-link branches no longer collapse two outcomes into one" do
    @auth_source "lib/barkpark_web/controllers/auth_controller.ex"
    @session_source "lib/barkpark_web/controllers/session_controller.ex"

    test "AuthController names BOTH outcomes of build_login_token/1" do
      source = File.read!(@auth_source)

      assert source =~ ":no_user ->"
      assert source =~ "{:error, _changeset} ->"

      assert source =~
               "NotificationWithhold.record(\"magic_link\", :no_recipient_by_construction)"

      assert source =~ "NotificationWithhold.record(\"magic_link\", :dispatch_crashed"
    end

    test "SessionController, the browser twin, names them too" do
      source = File.read!(@session_source)

      assert source =~ ":no_user ->"
      assert source =~ "{:error, _changeset} ->"

      assert source =~
               "NotificationWithhold.record(\"magic_link\", :no_recipient_by_construction)"

      assert source =~ "NotificationWithhold.record(\"magic_link\", :dispatch_crashed"
    end

    test "the registration path records a withheld confirmation instead of swallowing it" do
      source = File.read!(@auth_source)

      assert source =~ "NotificationWithhold.record(\"confirmation\", :dispatch_crashed"
    end

    test "no notifier-adjacent branch still ends at a bare catch-all :ok" do
      # The exact shape this slice removed: a catch-all whose whole body is `:ok`,
      # sitting in a function that reaches a notifier. Three of them existed.
      for path <- [@auth_source, @session_source] do
        source = File.read!(path)

        refute source =~ ~r/\n\s+_ ->\n\s+:ok\n\s+end\n\n\s+json\(conn/,
               "#{path} still collapses a notifier branch into a bare :ok"
      end
    end
  end

  # ── The excluded site stays excluded ───────────────────────────────────────

  describe "the airdrop grant path is deliberately untouched" do
    test "GrantNotifier.deliver_grant is called unconditionally, so it is not a withhold" do
      # Guard against a future edit turning the unconditional send into a branch.
      # airdrop.ex:254 calls deliver_grant with no surrounding condition; only a
      # documented best-effort PubSub toast is skipped there.
      source = File.read!("lib/barkpark_web/live/studio/studio_live/handlers/airdrop.ex")

      assert source =~ "Barkpark.Access.GrantNotifier.deliver_grant(grant.grantee_email"
      refute source =~ "NotificationWithhold"
    end
  end
end
