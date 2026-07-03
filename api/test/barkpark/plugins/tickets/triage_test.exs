defmodule Barkpark.Plugins.Tickets.TriageTest do
  @moduledoc """
  The pure triage ordering (charter Decision 3): open (oldest-waiting first) →
  answered (newest first) → closed (newest first). No DB, no clock except the
  `now` passed to `waiting_age/2`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tickets.Triage

  @now ~U[2026-01-01 12:00:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  describe "inbox_order/1 — status buckets" do
    test "open sorts before answered sorts before closed" do
      open = %{status: "open", waiting_since: ago(60)}
      answered = %{status: "answered", updated_at: ago(10)}
      closed = %{status: "closed", updated_at: ago(5)}

      ordered = Triage.inbox_order([closed, answered, open])

      assert Enum.map(ordered, & &1.status) == ["open", "answered", "closed"]
    end

    test "unknown statuses fall after closed" do
      closed = %{status: "closed", updated_at: ago(5)}
      weird = %{status: "archived", updated_at: ago(1)}

      assert Triage.inbox_order([weird, closed]) |> Enum.map(& &1.status) ==
               ["closed", "archived"]
    end
  end

  describe "inbox_order/1 — within the open bucket" do
    test "oldest waiting_since first (the person who waited longest is on top)" do
      waited_1h = %{status: "open", waiting_since: ago(3600), subject: "old"}
      waited_1m = %{status: "open", waiting_since: ago(60), subject: "new"}
      waited_10m = %{status: "open", waiting_since: ago(600), subject: "mid"}

      ordered = Triage.inbox_order([waited_1m, waited_10m, waited_1h])

      assert Enum.map(ordered, & &1.subject) == ["old", "mid", "new"]
    end

    test "an open ticket with no waiting_since sorts LAST among open (never masquerades as urgent)" do
      waited = %{status: "open", waiting_since: ago(60), subject: "has-stamp"}
      no_stamp = %{status: "open", subject: "no-stamp"}

      ordered = Triage.inbox_order([no_stamp, waited])

      assert Enum.map(ordered, & &1.subject) == ["has-stamp", "no-stamp"]
    end
  end

  describe "inbox_order/1 — within the answered/closed buckets" do
    test "answered sorted most-recent first" do
      old = %{status: "answered", updated_at: ago(600), subject: "old"}
      new = %{status: "answered", updated_at: ago(10), subject: "new"}

      assert Triage.inbox_order([old, new]) |> Enum.map(& &1.subject) == ["new", "old"]
    end
  end

  describe "inbox_order/1 — key spellings + timestamp formats" do
    test "string keys and ISO8601-string timestamps order identically to atoms/DateTimes" do
      # oldest via a string key + ISO string; should lead the open bucket.
      oldest = %{"status" => "open", "waiting_since" => "2026-01-01T10:00:00Z", "subject" => "2h"}
      newer = %{status: "open", waiting_since: ago(60), subject: "1m"}

      ordered = Triage.inbox_order([newer, oldest])

      assert Enum.map(ordered, &(&1[:subject] || &1["subject"])) == ["2h", "1m"]
    end
  end

  describe "waiting_age/2" do
    test "returns whole seconds waited, relative to now" do
      ticket = %{status: "open", waiting_since: ago(3600)}
      assert Triage.waiting_age(ticket, @now) == 3600
    end

    test "reads a string waiting_since" do
      ticket = %{"status" => "open", "waiting_since" => "2026-01-01T11:00:00Z"}
      assert Triage.waiting_age(ticket, @now) == 3600
    end

    test "nil when there is no waiting_since" do
      assert Triage.waiting_age(%{status: "open"}, @now) == nil
    end

    test "nil for an answered/closed ticket even though its stale waiting_since stamp persists" do
      # An operator answer does NOT clear waiting_since (only a reopen resets
      # it) — the age must still read nil, or the inbox would show a bogus
      # "waited 1h" on a row that is waiting on the SUBMITTER.
      assert Triage.waiting_age(%{status: "answered", waiting_since: ago(3600)}, @now) == nil

      assert Triage.waiting_age(
               %{"status" => "closed", "waiting_since" => "2026-01-01T11:00:00Z"},
               @now
             ) == nil
    end

    test "never negative even if the stamp is slightly ahead of now (clock skew)" do
      ticket = %{status: "open", waiting_since: DateTime.add(@now, 5, :second)}
      assert Triage.waiting_age(ticket, @now) == 0
    end
  end
end
