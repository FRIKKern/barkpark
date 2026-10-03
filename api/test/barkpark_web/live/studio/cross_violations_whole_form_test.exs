defmodule BarkparkWeb.Studio.CrossViolationsWholeFormTest do
  @moduledoc """
  A schema's cross-field warnings must be judged against the whole document,
  not against the fields the last keystroke posted.

  Found dogfooding: a new task created in Studio (lifecycle `open`) showed
  "1 ISSUE: A finished task should record an outcome summary" as soon as its
  title was typed. The task editor has field groups (Brief / Work / Close /
  System), the form posts only the visible group's inputs, and the autosave
  recomputed the cross-field rules from those params alone — so
  `lifecycle_status`, living on another group, read as absent and the
  "open tasks are exempt" arm of the rule failed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "memo",
          "title" => "Memo",
          "visibility" => "public",
          "groups" => [
            %{"name" => "brief", "title" => "Brief"},
            %{"name" => "system", "title" => "System"}
          ],
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string", "group" => "brief"},
            %{"name" => "summary", "title" => "Summary", "type" => "string", "group" => "brief"},
            %{
              "name" => "state",
              "title" => "State",
              "type" => "select",
              "options" => ["open", "done"],
              "group" => "system"
            }
          ],
          "cross_validations" => [
            %{
              "name" => "done_needs_summary",
              "title" => "A finished memo should have a summary",
              "rule" => %{
                "any" => [
                  %{"field" => "state", "operator" => "in", "value" => ["open"]},
                  %{"field" => "summary", "operator" => "non_empty"}
                ]
              },
              "level" => "warning",
              "fields" => ["summary"]
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "memo",
        %{"doc_id" => "m1", "title" => "Memo", "content" => %{"state" => "open"}},
        @dataset
      )

    :ok
  end

  test "typing on one group does not raise a warning the other group's values satisfy", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/memo/m1"))
    refute html =~ "A finished memo should have a summary"

    # The Brief group is the one on screen: its inputs are all the form posts.
    html =
      render_change(view, "autosave", %{"doc" => %{"title" => "Memo edited", "summary" => ""}})

    refute html =~ "A finished memo should have a summary",
           "an open memo was warned for lacking a summary after a title edit"
  end
end
