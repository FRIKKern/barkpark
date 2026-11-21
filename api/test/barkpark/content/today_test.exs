defmodule Barkpark.Content.TodayTest do
  @moduledoc """
  The `"$today"` token's meaning (task-f78a513602faee55), on a pinned clock.
  barkpark-studio's `fixtures/today-cases.json` holds these same cases with
  this module's answers (its `scripts/today-cases.exs`), and the Studio's
  `app/src/lib/today.ts` is tested against them, so both give one date.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Today

  # Every value a scope's `workspace_id` can carry that names no workspace with a
  # zone: today reads UTC, never a raise (a raise was a 500 on the read).
  @no_zone [
    {"nil (an internal global reader)", nil},
    {":shared_only (a request whose workspace did not resolve)", :shared_only},
    {"another atom", :global},
    {"a number", 123},
    {"an empty string", ""},
    {"a malformed id", "not-a-uuid"},
    {"a deleted workspace's id", "6f1d0c3a-9b8e-4d2f-a1c7-5e3b2a9d8c01"}
  ]

  for {name, id} <- @no_zone do
    @id id
    test "no workspace zone for #{name}: UTC, no raise" do
      assert Today.clock(@id, now: ~U[2026-11-20 23:30:00Z]).zone == "Etc/UTC"
    end
  end

  # {name, now (UTC), zone, value, answer}. Oslo is UTC+1, and UTC+2 from
  # 2026-03-29 01:00Z to 2026-10-25 01:00Z.
  @cases [
    {"23:30 UTC, Oslo is already tomorrow", "2026-11-20T23:30:00Z", "Europe/Oslo", "$today",
     "2026-11-21"},
    {"23:30 UTC, no zone reads UTC", "2026-11-20T23:30:00Z", "Etc/UTC", "$today", "2026-11-20"},
    {"an unknown zone reads UTC", "2026-11-20T23:30:00Z", "Not/AZone", "$today", "2026-11-20"},
    {"the night summer time starts, before the change", "2026-03-28T23:30:00Z", "Europe/Oslo",
     "$today", "2026-03-29"},
    {"summer time, 23:59:59 in Oslo", "2026-03-29T21:59:59Z", "Europe/Oslo", "$today",
     "2026-03-29"},
    {"summer time, 00:00 in Oslo", "2026-03-29T22:00:00Z", "Europe/Oslo", "$today", "2026-03-30"},
    {"the night summer time ends, 00:30 in Oslo", "2026-10-24T22:30:00Z", "Europe/Oslo", "$today",
     "2026-10-25"},
    {"winter time again, 23:30 in Oslo", "2026-10-25T22:30:00Z", "Europe/Oslo", "$today",
     "2026-10-25"},
    {"winter time again, 00:00 in Oslo", "2026-10-25T23:00:00Z", "Europe/Oslo", "$today",
     "2026-10-26"},
    {"the year, New Year's Eve 23:30 UTC in Oslo", "2026-12-31T23:30:00Z", "Europe/Oslo",
     "$today.year", "2027"},
    {"the year, the same instant in UTC", "2026-12-31T23:30:00Z", "Etc/UTC", "$today.year",
     "2026"},
    {"nested and in a list", "2026-11-20T23:30:00Z", "Europe/Oslo",
     %{"a" => %{"b" => "$today"}, "c" => ["$today", 1]},
     %{"a" => %{"b" => "2026-11-21"}, "c" => ["2026-11-21", 1]}},
    {"only the exact string is a token", "2026-11-20T23:30:00Z", "Europe/Oslo",
     ["$todayx", " $today", "fra $today", "$tomorrow", "$TODAY", "today"],
     ["$todayx", " $today", "fra $today", "$tomorrow", "$TODAY", "today"]},
    {"a fixed initial value starts as written", "2026-11-20T23:30:00Z", "Europe/Oslo",
     %{"publisert" => "2026-01-01", "tittel" => "Ny sak"},
     %{"publisert" => "2026-01-01", "tittel" => "Ny sak"}}
  ]

  for {name, now, zone, value, answer} <- @cases do
    test "case: #{name}" do
      {:ok, now, 0} = DateTime.from_iso8601(unquote(now))
      clock = %{now: now, zone: unquote(zone)}
      assert Today.resolve(unquote(Macro.escape(value)), clock) == unquote(Macro.escape(answer))
    end
  end

  test "a filter's operands resolve; no token leaves the term as it was, with no clock read" do
    clock = %{now: ~U[2026-11-20 23:30:00Z], zone: "Europe/Oslo"}

    assert Today.resolve(%{"content.sluttdato" => %{"lt" => "$today"}}, clock) ==
             %{"content.sluttdato" => %{"lt" => "2026-11-21"}}

    never = fn -> flunk("no token, so no clock is read") end
    plain = %{"content.sluttdato" => %{"gte" => "2026-01-01"}, "x" => ["$today?"], 1 => nil}
    assert Today.resolve(plain, never) == plain
    assert Today.resolve(nil, never) == nil
  end
end
