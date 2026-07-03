defmodule Barkpark.Plugins.Tickets.InboxPresenterTest do
  @moduledoc """
  Exhaustive unit coverage for the pure inbox render model (Tickets epic,
  Decision 3 + 5). This is the PRIMARY gate for the Studio operator-inbox
  slice: partitioning, ordering, age formatting boundaries and the seen-signal
  derivation are all decided here, with NO database and NO boot.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tickets.InboxPresenter

  @now ~U[2026-07-03 12:00:00Z]

  defp ago(secs), do: DateTime.add(@now, -secs, :second)

  # Build a ticket map with string keys (document JSON shape, Decision 2).
  defp ticket(overrides) do
    base = %{
      "id" => "t-#{System.unique_integer([:positive])}",
      "subject" => "Cannot log in",
      "status" => "open",
      "key_id" => "k1",
      "key_name" => "Gyldendal — Kari",
      "messages" => [],
      "submitter_seen_at" => nil,
      "waiting_since" => ago(3600)
    }

    Map.merge(base, Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
  end

  defp msg(kind, at, opts \\ []) do
    %{
      "id" => "m-#{System.unique_integer([:positive])}",
      "author_kind" => kind,
      "author_name" => Keyword.get(opts, :name, kind),
      "body" => Keyword.get(opts, :body, "hello"),
      "attachments" => Keyword.get(opts, :attachments, []),
      "at" => at
    }
  end

  describe "build/2 — partitioning by status (Decision 3)" do
    test "open → needs_answer, answered → waiting_on_them, closed → recently_closed" do
      tickets = [
        ticket(status: "open", id: "o1"),
        ticket(status: "answered", id: "a1", messages: [msg("operator", ago(100))]),
        ticket(status: "closed", id: "c1", messages: [msg("operator", ago(200))])
      ]

      model = InboxPresenter.build(tickets, @now)

      assert Enum.map(model.needs_answer, & &1.id) == ["o1"]
      assert Enum.map(model.waiting_on_them, & &1.id) == ["a1"]
      assert Enum.map(model.recently_closed, & &1.id) == ["c1"]
    end

    test "unknown/malformed status is dropped from every partition (fail-quiet)" do
      model = InboxPresenter.build([ticket(status: "banana", id: "x")], @now)

      assert model.needs_answer == []
      assert model.waiting_on_them == []
      assert model.recently_closed == []
      assert model.badge_count == 0
    end

    test "empty list yields empty partitions and a zero badge" do
      model = InboxPresenter.build([], @now)

      assert model == %{
               needs_answer: [],
               waiting_on_them: [],
               recently_closed: [],
               badge_count: 0
             }
    end

    test "a reopened ticket (status back to open) re-enters needs_answer" do
      # It has an operator answer in history but the submitter replied → open.
      reopened =
        ticket(
          status: "open",
          id: "re1",
          messages: [
            msg("submitter", ago(500)),
            msg("operator", ago(400)),
            msg("submitter", ago(60))
          ],
          waiting_since: ago(60)
        )

      model = InboxPresenter.build([reopened], @now)

      assert Enum.map(model.needs_answer, & &1.id) == ["re1"]
      assert model.waiting_on_them == []
    end
  end

  describe "build/2 — ordering" do
    test "needs_answer is oldest-waiting FIRST" do
      tickets = [
        ticket(status: "open", id: "young", waiting_since: ago(60)),
        ticket(status: "open", id: "oldest", waiting_since: ago(9000)),
        ticket(status: "open", id: "mid", waiting_since: ago(3600))
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.needs_answer, & &1.id) == ["oldest", "mid", "young"]
    end

    test "a nil waiting_since sorts LAST among open tickets" do
      tickets = [
        ticket(status: "open", id: "nil-ws", waiting_since: nil),
        ticket(status: "open", id: "real", waiting_since: ago(3600))
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.needs_answer, & &1.id) == ["real", "nil-ws"]
    end

    test "waiting_on_them is newest-activity FIRST" do
      tickets = [
        ticket(status: "answered", id: "stale", messages: [msg("operator", ago(9000))]),
        ticket(status: "answered", id: "fresh", messages: [msg("operator", ago(100))]),
        ticket(status: "answered", id: "mid", messages: [msg("operator", ago(3600))])
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.waiting_on_them, & &1.id) == ["fresh", "mid", "stale"]
    end

    test "recently_closed is newest-activity FIRST" do
      tickets = [
        ticket(status: "closed", id: "old", messages: [msg("operator", ago(9000))]),
        ticket(status: "closed", id: "new", messages: [msg("operator", ago(50))])
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.recently_closed, & &1.id) == ["new", "old"]
    end

    test "a ticket with NO parseable activity sorts LAST in waiting_on_them, not first" do
      tickets = [
        ticket(status: "answered", id: "no-activity", messages: [], waiting_since: nil),
        ticket(status: "answered", id: "fresh", messages: [msg("operator", ago(100))]),
        ticket(status: "answered", id: "stale", messages: [msg("operator", ago(9000))])
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.waiting_on_them, & &1.id) == ["fresh", "stale", "no-activity"]
    end

    test "a ticket with NO parseable activity sorts LAST in recently_closed" do
      tickets = [
        ticket(status: "closed", id: "ghost", messages: [], waiting_since: nil),
        ticket(status: "closed", id: "real", messages: [msg("operator", ago(50))])
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.recently_closed, & &1.id) == ["real", "ghost"]
    end

    test "messages-less answered ticket falls back to waiting_since for activity order" do
      tickets = [
        ticket(status: "answered", id: "via-ws", messages: [], waiting_since: ago(200)),
        ticket(status: "answered", id: "via-msg", messages: [msg("operator", ago(9000))])
      ]

      model = InboxPresenter.build(tickets, @now)
      assert Enum.map(model.waiting_on_them, & &1.id) == ["via-ws", "via-msg"]
    end
  end

  describe "build/2 — badge_count" do
    test "badge_count equals the number of needs_answer rows" do
      tickets = [
        ticket(status: "open"),
        ticket(status: "open"),
        ticket(status: "answered", messages: [msg("operator", ago(10))]),
        ticket(status: "closed", messages: [msg("operator", ago(10))])
      ]

      model = InboxPresenter.build(tickets, @now)
      assert model.badge_count == 2
      assert model.badge_count == length(model.needs_answer)
    end
  end

  describe "build/2 — row model" do
    test "carries id, key_name, subject, waiting_age, message_count, has_attachments?, seen" do
      t =
        ticket(
          status: "open",
          id: "row1",
          key_name: "Acme — Bob",
          subject: "Broken export",
          waiting_since: ago(7200),
          messages: [msg("submitter", ago(7200), attachments: ["asset-a"])]
        )

      [row] = InboxPresenter.build([t], @now).needs_answer

      assert row.id == "row1"
      assert row.key_name == "Acme — Bob"
      assert row.subject == "Broken export"
      assert row.waiting_age == "2h"
      assert row.message_count == 1
      assert row.has_attachments? == true
      # open ticket with no operator message → nothing to have seen
      assert row.seen == nil
    end

    test "has_attachments? is false when no message carries an attachment" do
      t = ticket(status: "open", messages: [msg("submitter", ago(10))])
      [row] = InboxPresenter.build([t], @now).needs_answer
      assert row.has_attachments? == false
    end

    test "has_attachments? is true if ANY message has an attachment" do
      t =
        ticket(
          status: "open",
          messages: [
            msg("submitter", ago(20)),
            msg("submitter", ago(10), attachments: ["a", "b"])
          ]
        )

      [row] = InboxPresenter.build([t], @now).needs_answer
      assert row.has_attachments? == true
    end

    test "message_count reflects the whole thread length" do
      t =
        ticket(
          status: "answered",
          messages: [msg("submitter", ago(30)), msg("operator", ago(20)), msg("submitter", ago(10))]
        )

      [row] = InboxPresenter.build([t], @now).waiting_on_them
      assert row.message_count == 3
    end

    test "missing/empty subject falls back to (no subject)" do
      assert [%{subject: "(no subject)"}] =
               InboxPresenter.build([ticket(status: "open", subject: "")], @now).needs_answer

      assert [%{subject: "(no subject)"}] =
               InboxPresenter.build([ticket(status: "open", subject: nil)], @now).needs_answer
    end

    test "missing key_name falls back to —" do
      assert [%{key_name: "—"}] =
               InboxPresenter.build([ticket(status: "open", key_name: nil)], @now).needs_answer
    end
  end

  describe "humanize_age/2 — boundaries" do
    test "sub-minute is \"now\"" do
      assert InboxPresenter.humanize_age(ago(0), @now) == "now"
      assert InboxPresenter.humanize_age(ago(59), @now) == "now"
    end

    test "minute boundary" do
      assert InboxPresenter.humanize_age(ago(60), @now) == "1m"
      assert InboxPresenter.humanize_age(ago(3599), @now) == "59m"
    end

    test "hour boundary" do
      assert InboxPresenter.humanize_age(ago(3600), @now) == "1h"
      assert InboxPresenter.humanize_age(ago(86_399), @now) == "23h"
    end

    test "day boundary" do
      assert InboxPresenter.humanize_age(ago(86_400), @now) == "1d"
      assert InboxPresenter.humanize_age(ago(172_800), @now) == "2d"
    end

    test "future timestamp (clock skew) clamps to now" do
      assert InboxPresenter.humanize_age(DateTime.add(@now, 500, :second), @now) == "now"
    end

    test "nil / unparseable → em dash" do
      assert InboxPresenter.humanize_age(nil, @now) == "—"
      assert InboxPresenter.humanize_age("not-a-date", @now) == "—"
    end

    test "accepts an ISO8601 string timestamp" do
      iso = DateTime.to_iso8601(ago(3600))
      assert InboxPresenter.humanize_age(iso, @now) == "1h"
    end
  end

  describe "seen_signal/2 — the no-push delivery proof (Decision 3)" do
    test "nil when there is no operator message yet" do
      t = ticket(status: "open", messages: [msg("submitter", ago(10))])
      assert InboxPresenter.seen_signal(t, @now) == nil
    end

    test "\"not seen yet\" when the submitter has not read the operator's answer" do
      t =
        ticket(
          status: "answered",
          submitter_seen_at: nil,
          messages: [msg("submitter", ago(300)), msg("operator", ago(100))]
        )

      assert InboxPresenter.seen_signal(t, @now) == "not seen yet"
    end

    test "\"not seen yet\" when seen predates the last operator message" do
      t =
        ticket(
          status: "answered",
          submitter_seen_at: ago(200),
          messages: [msg("operator", ago(100))]
        )

      assert InboxPresenter.seen_signal(t, @now) == "not seen yet"
    end

    test "\"seen <age> ago\" when seen is later than the last operator message" do
      t =
        ticket(
          status: "answered",
          submitter_seen_at: ago(7200),
          messages: [msg("operator", ago(9000))]
        )

      assert InboxPresenter.seen_signal(t, @now) == "seen 2h ago"
    end

    test "\"seen just now\" when seen is under a minute ago" do
      t =
        ticket(
          status: "answered",
          submitter_seen_at: ago(30),
          messages: [msg("operator", ago(300))]
        )

      assert InboxPresenter.seen_signal(t, @now) == "seen just now"
    end

    test "uses the LATEST operator message when several exist" do
      # seen(90s) is after the first operator msg (200s) but before the
      # latest (30s) → still not seen.
      t =
        ticket(
          status: "answered",
          submitter_seen_at: ago(90),
          messages: [msg("operator", ago(200)), msg("operator", ago(30))]
        )

      assert InboxPresenter.seen_signal(t, @now) == "not seen yet"
    end

    test "surfaces on the waiting_on_them row via build/2" do
      t =
        ticket(
          status: "answered",
          submitter_seen_at: ago(3600),
          messages: [msg("operator", ago(7200))]
        )

      [row] = InboxPresenter.build([t], @now).waiting_on_them
      assert row.seen == "seen 1h ago"
    end
  end

  describe "field-shape tolerance" do
    test "atom-keyed ticket maps produce the same model as string-keyed" do
      atom_ticket = %{
        id: "atom1",
        subject: "Atom subject",
        status: "answered",
        key_name: "Atom Key",
        submitter_seen_at: ago(30),
        waiting_since: ago(3600),
        messages: [%{author_kind: :operator, author_name: "Op", body: "hi", attachments: ["z"], at: ago(120)}]
      }

      [row] = InboxPresenter.build([atom_ticket], @now).waiting_on_them

      assert row.id == "atom1"
      assert row.subject == "Atom subject"
      assert row.key_name == "Atom Key"
      assert row.has_attachments? == true
      assert row.message_count == 1
      assert row.seen == "seen just now"
    end
  end
end
