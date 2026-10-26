defmodule Barkpark.Content.PreviewTextDateTimeTest do
  @moduledoc """
  task-ecaaa898e346dc73: a `|date` of a date-time can ride as a marker, which
  the LiveView Studio draws as a `<time>` the browser shows as its day in the
  workspace time zone.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PreviewText

  defp none(_), do: nil
  @late %{"at" => "2026-10-08T23:30:00Z", "day" => "2026-10-08", "place" => "Hall"}

  test "the default shows a date-time's UTC day, as before" do
    assert PreviewText.format("at|date", @late, &none/1) == "08.10.2026"
  end

  test "date_time formats a date-time; a plain date stays its own day" do
    opts = [date_time: &PreviewText.date_time_marker/1]
    marked = PreviewText.format(%{"parts" => ["at|date", "place"]}, @late, &none/1, opts)

    assert marked == "\u{E000}2026-10-08T23:30:00Z\u{E001} · Hall"
    assert PreviewText.format("day|date", @late, &none/1, opts) == "08.10.2026"

    assert PreviewText.split_date_times(marked) == [
             {:date_time, "2026-10-08T23:30:00Z", "08.10.2026"},
             " · Hall"
           ]

    assert PreviewText.plain(marked) == "08.10.2026 · Hall"
    assert PreviewText.plain("No dates") == "No dates"
  end

  test "a marker inside a template, under |lower, still reads back" do
    opts = [date_time: &PreviewText.date_time_marker/1]
    text = PreviewText.format("Starts {at|date|lower}", @late, &none/1, opts)

    assert ["Starts ", {:date_time, "2026-10-08T23:30:00Z", "08.10.2026"}] =
             PreviewText.split_date_times(text)
  end
end
