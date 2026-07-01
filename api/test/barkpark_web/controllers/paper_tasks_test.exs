defmodule BarkparkWeb.PaperTasksTest do
  @moduledoc """
  Render contract for the "Driven tasks" section (lvw-t8 reverse view):
  empty-in → empty-out, satisfied vs unmet claim markers, evidence
  surfacing, progress omission, and HTML escaping of every user string.
  """

  use ExUnit.Case, async: true

  alias BarkparkWeb.PaperTasks

  defp task(overrides \\ %{}) do
    Map.merge(
      %{
        doc_id: "t-1",
        title: "Ship the reverse view",
        lifecycle_status: "open",
        via: ["design_doc"],
        criteria: [],
        criteria_progress: nil,
        satisfied: false
      },
      overrides
    )
  end

  test "empty (or non-list) input renders nothing" do
    assert PaperTasks.section_html([]) == ""
    assert PaperTasks.section_html(%{tasks: []}) == ""
    assert PaperTasks.section_html(nil) == ""
    assert PaperTasks.section_html("junk") == ""
  end

  test "accepts the driven_tasks/2 result map and renders the section chrome" do
    html = PaperTasks.section_html(%{tasks: [task()]})

    assert html =~ ~s(class="bp-paper-tasks")
    assert html =~ ~s(aria-label="Driven tasks")
    assert html =~ "Driven tasks"
    assert html =~ "Ship the reverse view"
    assert html =~ "open"
  end

  test "a satisfied claim renders ✓ + evidence; an unmet one renders ○ without" do
    html =
      PaperTasks.section_html([
        task(%{
          criteria: [
            %{criterion: "claim one", met: true, evidence: "PR #999"},
            %{criterion: "claim two", met: false, evidence: nil}
          ],
          criteria_progress: %{met: 1, total: 2}
        })
      ])

    assert html =~ "✓"
    assert html =~ "claim one"
    assert html =~ "PR #999"
    assert html =~ "○"
    assert html =~ "claim two"
    assert html =~ "1/2 met"
  end

  test "nil criteria_progress renders no progress chip (never 0/0)" do
    html = PaperTasks.section_html([task()])

    refute html =~ "met</span>"
    refute html =~ "0/0"
  end

  test "title falls back to doc_id; a task with no doc_id is skipped entirely" do
    html = PaperTasks.section_html([task(%{title: nil}), %{title: "ghost"}])

    assert html =~ "t-1"
    refute html =~ "ghost"

    assert PaperTasks.section_html([%{title: "only ghosts"}]) == ""
  end

  test "every user string is HTML-escaped" do
    html =
      PaperTasks.section_html([
        task(%{
          title: "<script>alert(1)</script>",
          lifecycle_status: "<b>open</b>",
          criteria: [
            %{criterion: "<img src=x>", met: true, evidence: "<svg onload=x>"}
          ],
          criteria_progress: %{met: 1, total: 1}
        })
      ])

    refute html =~ "<script>"
    refute html =~ "<img"
    refute html =~ "<svg"
    refute html =~ "<b>open</b>"
    assert html =~ "&lt;script&gt;"
  end
end
