defmodule Barkpark.Accounts.NotificationWithholdTest do
  @moduledoc """
  The api-side withhold funnel.

  THE DEFECT THIS PINS: on origin/main every branch that decided NOT to send an
  account notification did so silently. A deliberate anti-enumeration skip and a
  real user whose token mint failed produced the SAME nothing, so nobody could
  answer "did we choose not to email this person, or is email broken for them?".
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.Accounts
  alias Barkpark.Accounts.NotificationWithhold
  alias Barkpark.Audit.Event
  alias Barkpark.Repo

  @password "correct-horse-battery"

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

  describe "the closed vocabulary is cloud's, not a new coinage" do
    test "both reasons are the atoms the cloud funnel already uses" do
      # Cited by SYMBOL, never by line — a line anchor is the part that rots.
      # :no_recipient_by_construction — BarkparkCloud.Notifications.deliver_fleet_digest/1
      # :dispatch_crashed             — BarkparkCloud.Notifications.dispatch_event/3
      assert Enum.sort(NotificationWithhold.reasons()) ==
               Enum.sort([:no_recipient_by_construction, :dispatch_crashed])
    end

    test "the notification kinds cover every UserNotifier deliver_*" do
      assert Enum.sort(NotificationWithhold.notifications()) ==
               Enum.sort(~w(confirmation magic_link reset already_registered))
    end
  end

  describe "a CONSENTED withhold is the absence of a person, so it writes nothing" do
    test "no_recipient_by_construction records zero events and persists no address" do
      before = length(withhold_events())

      assert {:ok, 0} = NotificationWithhold.record("reset", :no_recipient_by_construction)

      assert length(withhold_events()) == before
    end

    test "it stays zero however many times it is called (no probe amplification)" do
      before = length(withhold_events())

      for _ <- 1..25 do
        NotificationWithhold.record("magic_link", :no_recipient_by_construction)
      end

      assert length(withhold_events()) == before
    end
  end

  describe "a REAL withhold from a REAL user is recorded" do
    test "dispatch_crashed writes one auth audit event naming the notification and reason" do
      u = user("recorded@example.com")
      before = length(withhold_events())

      assert {:ok, 1} =
               NotificationWithhold.record("confirmation", :dispatch_crashed,
                 user_id: u.id,
                 detail: "token_mint_failed"
               )

      events = withhold_events()
      assert length(events) == before + 1

      event = List.last(events)
      assert event.category == "auth"
      assert event.action == "notification_withheld"
      assert event.subject == "confirmation"
      assert event.actor_id == u.id
      assert event.metadata["notification"] == "confirmation"
      assert event.metadata["reason"] == "dispatch_crashed"
      assert event.metadata["detail"] == "token_mint_failed"
    end

    test "THE POINT: consented and broken are distinguishable by reason" do
      u = user("distinct@example.com")

      {:ok, consented} = NotificationWithhold.record("magic_link", :no_recipient_by_construction)

      {:ok, broken} =
        NotificationWithhold.record("magic_link", :dispatch_crashed, user_id: u.id)

      # The whole defect was that these two produced the same nothing.
      refute consented == broken
      assert consented == 0
      assert broken == 1

      assert [event] = Enum.filter(withhold_events(), &(&1.actor_id == u.id))
      assert event.metadata["reason"] == "dispatch_crashed"
    end
  end

  describe "the funnel refuses to lie" do
    test "a dispatch_crashed naming NOBODY is refused loudly, not written" do
      before = length(withhold_events())

      log =
        capture_log(fn ->
          assert {:ok, 0} =
                   NotificationWithhold.record("confirmation", :dispatch_crashed, user_id: nil)
        end)

      assert log =~ "notification_withheld"
      assert log =~ "no user_id"
      # A row naming nobody answers nobody's question — so none was written.
      assert length(withhold_events()) == before
    end

    test "an unrecognised reason is LOUD, never a quiet zero" do
      before = length(withhold_events())

      log =
        capture_log(fn ->
          assert {:ok, 0} = NotificationWithhold.record("confirmation", :made_up_reason)
        end)

      assert log =~ "refusing an unrecognised withhold"
      assert log =~ "made_up_reason"
      assert length(withhold_events()) == before
    end

    test "an unrecognised notification is LOUD too" do
      log =
        capture_log(fn ->
          assert {:ok, 0} =
                   NotificationWithhold.record(
                     "not_a_notification",
                     :no_recipient_by_construction
                   )
        end)

      assert log =~ "refusing an unrecognised withhold"
    end
  end

  describe "the :dispatch_crashed branch is reachable, not dead code" do
    test "build_email_token/2 really does return {:error, _} when the user row is gone" do
      # This is the reachable cause named in the row: assoc_constraint(:user).
      # In production it is a mid-flight race (the row vanishes between the read
      # and the token insert); here it is reproduced deterministically so the
      # branch the funnel now guards is proved to be LIVE code, not decoration.
      u = user("vanishing@example.com")
      Repo.delete!(u)

      assert {:error, %Ecto.Changeset{}} = Accounts.build_email_token(u, "confirm")
    end
  end
end
