defmodule Barkpark.Content.TodayTest do
  @moduledoc """
  The `"$today"` token's meaning (task-f78a513602faee55), on a pinned clock:
  the workspace's date for a date field, the instant for a datetime field,
  a declared string keeps the literal, and only the exact string is a token.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Today

  # 23:30 UTC on 20 November: Oslo (UTC+1) is already on the 21st.
  @late %{now: ~U[2026-11-20 23:30:00.123456Z], zone: "Europe/Oslo"}

  @fields [
    %{"name" => "publisert", "type" => "date"},
    %{"name" => "tid", "type" => "datetime"},
    %{"name" => "tittel", "type" => "string"},
    %{"name" => "meta", "type" => "object", "fields" => [%{"name" => "dag", "type" => "date"}]}
  ]

  test "at 23:30 UTC a date field gets Oslo's date, already tomorrow" do
    assert Today.date(@late) == "2026-11-21"
    assert Today.date(%{@late | zone: "Etc/UTC"}) == "2026-11-20"
    assert Today.date(%{@late | zone: "Not/AZone"}) == "2026-11-20"
  end

  test "initial values resolve by field type; only the exact string is a token" do
    values = %{
      "publisert" => "$today",
      "tid" => "$today",
      "tittel" => "$today",
      "meta" => %{"dag" => "$today"},
      "undeclared" => "$today",
      "year" => "$today.year",
      "a" => "$todayx",
      "b" => " $today",
      "c" => "fra $today",
      "d" => "$tomorrow"
    }

    assert Today.resolve_initial(values, @fields, @late) == %{
             "publisert" => "2026-11-21",
             "tid" => "2026-11-20T23:30:00.123Z",
             "tittel" => "$today",
             "meta" => %{"dag" => "2026-11-21"},
             "undeclared" => "2026-11-21",
             "year" => "2026",
             "a" => "$todayx",
             "b" => " $today",
             "c" => "fra $today",
             "d" => "$tomorrow"
           }
  end

  test "a filter resolves per field; no token or an odd shape comes back as it was" do
    filter = %{
      "content.publisert" => %{"gte" => "$today"},
      "content.tid" => %{"lt" => "$today"},
      "$or" => [%{"content.publisert" => %{"is" => "null"}}, "odd"]
    }

    assert Today.resolve_filter(filter, @fields, @late) == %{
             "content.publisert" => %{"gte" => "2026-11-21"},
             "content.tid" => %{"lt" => "2026-11-20T23:00:00.000Z"},
             "$or" => [%{"content.publisert" => %{"is" => "null"}}, "odd"]
           }

    never = fn -> flunk("no token, so no clock is read") end
    plain = %{"content.publisert" => %{"gte" => "2026-01-01"}, "x" => ["$today?"], 1 => nil}
    assert Today.resolve_filter(plain, @fields, never) == plain
    assert Today.resolve_initial(%{"k" => "v"}, nil, never) == %{"k" => "v"}
    assert Today.resolve_filter(nil, @fields, never) == nil
  end
end
