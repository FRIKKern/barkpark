defmodule BarkparkWeb.BulldocsReaderCardsVisibilityTest do
  @moduledoc """
  task-e5c77251c2de9c81: the anonymous paper reader's side sections read fields
  of OTHER documents straight off their raw content, never through `Envelope`:

    * "Related papers" (backlinks): `Graph.reverse_referencers/2` copied
      `description` / `event_type` off each citing document;
    * `paper-links` cards: `Content.Papers.resolve_paper_link_details/3` copied
      the same two keys off each linked paper;
    * "Driven tasks": `Tasks.Expectations` rendered each citing task's
      `acceptance_criteria` (criterion text AND evidence).

  So a field the tenant's schema declares `private` was redacted on
  `/v1/data/doc` and printed on `/papers/:slug` to anyone. Every card now reads
  through `Envelope.render/3` as the anonymous caller, under the schema the
  reader already resolved for the body (paper) or one lookup made only when a
  task cites the paper (task).

  Each surface is checked on its own: the dead HTTP render (what a crawler
  receives on the wire), the connected LiveView mount, and the connected
  re-render after a linked paper changes (`refetch/1`) and after the relation
  graph changes (`paper_relations_changed`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tenancy}
  alias Barkpark.Content.Graph
  alias Barkpark.Tasks.Expectations

  @ds "production"
  @target "rc-target"
  @citing "rc-citing"
  @linked "rc-linked"
  @task "rc-task"

  # marker => section that would be leaking it
  @private_markers [
    {"Citing paper hidden summary zq8", "backlink card description"},
    {"Linked paper hidden summary zq7", "paper-links card description"},
    {"Hidden criterion text zq9", "driven-task criterion text"},
    {"Hidden evidence zq10", "driven-task criterion evidence"}
  ]

  defp body(text) do
    [
      %{"id" => "title", "type" => "heading", "level" => 1, "text" => text},
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Body."}]
      }
    ]
  end

  setup do
    Barkpark.LabelFixtures.register_tags!(@ds)

    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    # The tenant's own `paper` and `task` schemas, each declaring the card
    # field private. `event_type` stays public: it is the per-card control.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "description", "type" => "text", "private" => true},
            %{"name" => "event_type", "type" => "string"}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "task",
          "title" => "Task",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "acceptance_criteria", "type" => "array", "private" => true}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @linked,
          blocks: body("Linked paper"),
          description: "Linked paper hidden summary zq7",
          event_type: "linked-control"
        })
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @target,
          blocks:
            body("Target paper") ++
              [%{"id" => "links", "type" => "paper-links", "refs" => [%{"slug" => @linked}]}]
        })
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @citing,
          blocks: body("Citing paper"),
          description: "Citing paper hidden summary zq8",
          event_type: "citing-control"
        })
      )

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "_id" => @task,
          "title" => "Driving task",
          # The label spine (description + weighted tags) the publish wall wants.
          "content" =>
            Map.merge(Barkpark.LabelFixtures.weighted_labels(), %{
              "brief" => Barkpark.TaskBriefFixtures.brief(),
              "kind" => "task",
              "lifecycle_status" => "open",
              "acceptance_criteria" => [
                %{
                  "criterion" => "Hidden criterion text zq9",
                  "met" => true,
                  "evidence" => "Hidden evidence zq10"
                }
              ]
            })
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document(@task, "task", @ds, scope)

    Content.add_edges(
      [
        %{from_id: @citing, to_id: @target, kind: "references"},
        %{from_id: @task, to_id: @target, kind: "design_doc"}
      ],
      [dataset: @ds] ++ scope
    )

    %{scope: scope}
  end

  defp leaks(html) do
    for {marker, section} <- @private_markers, html =~ marker, do: section
  end

  # CONTROLS: every section rendered, and the public `event_type` still reads,
  # so each "no leak" below is not vacuous.
  defp assert_sections_rendered(html, surface) do
    for control <- [
          "Citing paper",
          "Citing control",
          "Linked paper",
          "linked-control",
          "Driving task"
        ] do
      assert html =~ control, "#{surface}: control #{inspect(control)} missing"
    end
  end

  test "the dead HTTP render (the bytes on the wire) prints no private card field", %{conn: conn} do
    html = conn |> get("/papers/#{@target}") |> html_response(200)

    assert_sections_rendered(html, "dead render")
    assert leaks(html) == []
  end

  test "the connected mount prints no private card field", %{conn: conn} do
    {:ok, view, _dead_html} = live(conn, "/papers/#{@target}")
    html = render(view)

    assert_sections_rendered(html, "connected mount")
    assert leaks(html) == []
  end

  test "the connected re-renders (linked paper changed, relations changed) print no private card field",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/papers/#{@target}")

    send(view.pid, {:document_changed, %{type: "paper", doc_id: @linked}})
    html = render(view)
    assert_sections_rendered(html, "refetch")
    assert leaks(html) == []

    send(view.pid, {:paper_relations_changed, %{}})
    html = render(view)
    assert_sections_rendered(html, "relations changed")
    assert leaks(html) == []
  end

  describe "callers outside the anonymous reader are unchanged" do
    test "Studio's paper-links palette (no :paper_schema) still reads the raw content", %{
      scope: scope
    } do
      details =
        Content.Papers.resolve_paper_link_details(
          [%{"id" => "l", "type" => "paper-links", "refs" => [%{"slug" => @linked}]}],
          @ds,
          scope ++ [published_only: true]
        )

      assert details[@linked].description == "Linked paper hidden summary zq7"
    end

    test "an authenticated reverse_referencers walk (no published_only) still reads the raw content",
         %{scope: scope} do
      [ref] =
        @target
        |> Graph.reverse_referencers([dataset: @ds] ++ scope)
        |> Enum.filter(&(&1.from_doc_id == @citing))

      assert ref.description == "Citing paper hidden summary zq8"
    end

    test "driven tasks without :anonymous_task_schema still read the raw criteria", %{
      scope: scope
    } do
      %{tasks: [task]} = Expectations.driven_tasks(@target, [dataset: @ds] ++ scope)
      assert [%{criterion: "Hidden criterion text zq9"}] = task.criteria
    end
  end

  test "a citing type the walk holds no schema for shows no description (fail closed)", %{
    scope: scope
  } do
    [ref] =
      @target
      |> Graph.reverse_referencers([dataset: @ds, published_only: true] ++ scope)
      |> Enum.filter(&(&1.from_doc_id == @citing))

    assert ref.description == nil
    assert ref.event_type == nil
    assert ref.title == "Citing paper"
  end
end
