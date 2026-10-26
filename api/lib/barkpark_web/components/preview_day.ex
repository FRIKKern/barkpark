defmodule BarkparkWeb.PreviewDay do
  @moduledoc """
  A list preview's `|date` of a date-time, shown as the day it is in the
  workspace time zone (task-ecaaa898e346dc73), as Sanity shows it to an
  editor in that zone: 2026-10-08T23:30:00Z reads 09.10.2026 in Oslo.

  Barkpark has no time zone database, so the browser converts. `text/1`
  renders a preview line whose date-times are `PreviewText.date_time_marker/1`
  markers: each becomes a `<time data-preview-day>` holding the UTC day, and
  `assets/js/preview_day.js` rewrites it to the day in the zone the Studio
  shell names in `data-time-zone` (`Tenancy.workspace_time_zone/1`), or the
  browser's own zone when the workspace sets none.
  """

  use Phoenix.Component

  alias Barkpark.Content.PreviewText

  attr :text, :string, required: true

  def text(assigns) do
    assigns = assign(assigns, :pieces, PreviewText.split_date_times(assigns.text))

    ~H"""
    <%= for piece <- @pieces do %><%= case piece do %><% {:date_time, iso, day} -> %><time datetime={iso} data-preview-day><%= day %></time><% text -> %><%= text %><% end %><% end %>
    """
  end
end
