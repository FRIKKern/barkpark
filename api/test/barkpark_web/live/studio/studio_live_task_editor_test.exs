defmodule BarkparkWeb.Studio.StudioLiveTaskEditorTest do
  @moduledoc """
  Studio editor behaviour for `task` documents (tasks-studio):

    * `lifecycle_status` renders as a select with the five
      `Barkpark.Tasks.lifecycle_statuses/0` options;
    * v1 `array` / `object` fields (`dependencies`, `claim`) render as
      read-only JSON with NO form input;
    * a Classic editor save PRESERVES `dependencies` / `claim` (and any
      non-schema content key) byte-identically — the save path merges
      over existing content for fields the form does not manage
      (`Content.classic_save_content/4`);
    * `"number"`-typed schema fields (`priority`) are coerced from the
      form's string to an integer/float at the save boundary
      (`Content.build_content/2`'s `coerce_field_value/2`), so the task
      validator's integer-0..4 priority check passes instead of
      hard-failing the save.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  @claim %{"worker" => "w1", "ts_iso" => "2026-06-01T00:00:00Z", "epoch" => 1}
  @deps ["bd-a1", "bd-b2"]

  setup %{conn: conn} do
    # Register the task schema exactly as the plugin does — derived from
    # the single source of truth, so the lifecycle_status select shape is
    # the REAL one, not a test fixture.
    schema = Barkpark.Tasks.task_schema(@dataset)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => schema.name,
          "title" => schema.title,
          "icon" => schema.icon,
          "visibility" => schema.visibility,
          "fields" => schema.fields
        },
        @dataset
      )

    {:ok, _task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "tsk1",
          "title" => "Wire the bridge",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "assignee" => "agent-7",
            "dependencies" => @deps,
            "claim" => @claim
          }
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  test "lifecycle_status renders as a select with the five lifecycle options", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/studio/#{@dataset}/task/tsk1")

    assert html =~
             ~r{<select[^>]*name="doc\[lifecycle_status\]"[^>]*class="form-input"}

    for status <- Barkpark.Tasks.lifecycle_statuses() do
      assert html =~ ~s(<option value="#{status}"),
             "expected lifecycle option #{inspect(status)}"
    end

    assert html =~ ~r{<option value="open"[^>]*selected}
  end

  test "dependencies/claim render read-only JSON with no form input", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/studio/#{@dataset}/task/tsk1")

    # No input that would submit the structured values as strings.
    refute html =~ ~s(name="doc[dependencies]")
    refute html =~ ~s(name="doc[claim]")

    # Read-only JSON display, with the muted hint.
    assert html =~ ~s(data-readonly-field="dependencies")
    assert html =~ ~s(data-readonly-field="claim")
    assert html =~ "bd-a1"
    assert html =~ "ts_iso"
    assert html =~ "read-only — managed via API"
  end

  test "a Studio save preserves dependencies and claim byte-identically", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/task/tsk1")

    view
    |> form("#editor-form", %{
      "doc" => %{
        "title" => "Wire the bridge v2",
        "lifecycle_status" => "in_progress"
      }
    })
    |> render_submit()

    {:ok, saved} = Content.get_document("drafts.tsk1", "task", @dataset)

    # Form-managed fields took the submitted values…
    assert saved.title == "Wire the bridge v2"
    assert saved.content["lifecycle_status"] == "in_progress"
    assert saved.content["kind"] == "task"
    assert saved.content["assignee"] == "agent-7"

    # …and the structured fields the form does NOT manage survived intact.
    assert saved.content["dependencies"] == @deps
    assert saved.content["claim"] == @claim
  end

  test ~s(priority submitted as "2" persists as integer 2 — save must not error), %{conn: conn} do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/task/tsk1")

    html =
      view
      |> form("#editor-form", %{"doc" => %{"priority" => "2"}})
      |> render_submit()

    refute html =~ "Save failed"

    # The persisted draft is the real proof the save succeeded: a failed
    # upsert (the pre-coercion string-priority hard-reject) writes nothing.
    {:ok, saved} = Content.get_document("drafts.tsk1", "task", @dataset)
    assert saved.content["priority"] === 2

    # Coercion did not disturb the preserved structured fields.
    assert saved.content["dependencies"] == @deps
    assert saved.content["claim"] == @claim
  end

  test "empty priority saves cleanly and stores no priority key", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/task/tsk1")

    html =
      view
      |> form("#editor-form", %{"doc" => %{"priority" => "", "title" => "Still fine"}})
      |> render_submit()

    refute html =~ "Save failed"

    {:ok, saved} = Content.get_document("drafts.tsk1", "task", @dataset)
    assert saved.title == "Still fine"
    refute Map.has_key?(saved.content, "priority")
  end
end
