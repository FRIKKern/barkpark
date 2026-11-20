defmodule Barkpark.StructureTodayTest do
  @moduledoc """
  `"$today"` on the server (task-f78a513602faee55). A desk list's filter
  keeps the token as written and every list read compares with that
  request's date; an API create of a type whose `initial_values` say
  `"$today"` stores the workspace's date. HSO's «Kommende» / «Gjennomførte»
  split `arrangement.sluttdato` on today; Sanity writes those as
  `sluttdato >= now()` and `initialValue: () => new Date()`.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Structure
  alias Barkpark.Tenancy

  @dataset "today-#{System.unique_integer([:positive])}"

  @arrangement %{
    "name" => "arrangement",
    "title" => "Arrangement",
    "visibility" => "public",
    "fields" => [
      %{"name" => "title", "type" => "string"},
      %{"name" => "sluttdato", "type" => "date"},
      %{"name" => "publisert", "type" => "date"}
    ],
    "initial_values" => %{"publisert" => "$today"}
  }

  @kommende %{"content.sluttdato" => %{"gte" => "$today"}}
  @gjennomforte %{"content.sluttdato" => %{"lt" => "$today"}}

  defp desk!(items) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "type" => "array"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
  end

  defp events!(dates) do
    {:ok, _} = Content.upsert_schema(@arrangement, @dataset)

    for {id, date} <- dates do
      content = if date, do: %{"sluttdato" => date}, else: %{}

      {:ok, _} =
        Content.create_document(
          "arrangement",
          %{"doc_id" => id, "title" => id, "content" => content},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "arrangement", @dataset)
    end
  end

  defp titles(filter, opts) do
    "arrangement"
    |> Content.list_documents(@dataset, [perspective: :published, filter_map: filter] ++ opts)
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end

  test "a desk list filtered on sluttdato gte $today drops yesterday's event" do
    events!([{"i-gar", "2026-11-19"}, {"i-dag", "2026-11-20"}, {"uten-dato", nil}])

    desk!([
      %{
        "kind" => "documentTypeList",
        "type" => "arrangement",
        "title" => "Kommende",
        "filter" => @kommende
      },
      %{
        "kind" => "documentTypeList",
        "type" => "arrangement",
        "title" => "Gjennomførte",
        "filter" => @gjennomforte
      }
    ])

    by_title = Map.new(Structure.build(@dataset).items, &{&1.title, &1})

    # The desk serves the filter as written; each read resolves it.
    assert by_title["Kommende"].filter == @kommende
    now = [now: ~U[2026-11-20 10:00:00Z]]
    assert titles(by_title["Kommende"].filter, now) == ["i-dag"]
    # No date: GROQ's comparison with null is false, so neither list has it.
    assert titles(by_title["Gjennomførte"].filter, now) == ["i-gar"]
    # The next day, the same stored filter moves the event over.
    assert titles(@kommende, now: ~U[2026-11-21 10:00:00Z]) == []
  end

  test "$today is a token in every filter form: operator, shorthand eq and in" do
    events!([{"i-gar", "2026-11-19"}, {"i-dag", "2026-11-20"}])
    now = [now: ~U[2026-11-20 10:00:00Z]]

    assert titles(%{"content.sluttdato" => "$today"}, now) == ["i-dag"]
    assert titles(%{"content.sluttdato" => %{"eq" => "$today"}}, now) == ["i-dag"]

    assert titles(%{"content.sluttdato" => %{"in" => ["$today", "2026-11-19"]}}, now) == [
             "i-dag",
             "i-gar"
           ]

    # In a longer string it is text: nothing is dated "fra $today".
    assert titles(%{"content.sluttdato" => "fra $today"}, now) == []
  end

  test "one workspace read per request, however many filters and queries hold $today" do
    ws = create_workspace!("today-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.set_workspace_time_zone(ws.id, "Europe/Oslo")
    test_pid = self()
    handler = "today-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _e, _m, meta, _ ->
        if self() == test_pid and meta[:source] == "workspaces",
          do: send(test_pid, :workspace_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    filter = %{
      "content.sluttdato" => %{"gte" => "$today"},
      "content.publisert" => %{"lt" => "$today"}
    }

    opts = [perspective: :drafts, filter_map: filter, workspace_id: ws.id]
    Content.list_documents("arrangement", @dataset, opts)
    Content.count_documents("arrangement", @dataset, opts)

    assert_received :workspace_read
    refute_received :workspace_read
  end

  test "a read whose workspace did not resolve (:shared_only) answers in UTC, never a raise" do
    events!([{"i-dag", "2026-11-20"}])
    opts = [now: ~U[2026-11-20 23:30:00Z], workspace_id: :shared_only]
    assert is_list(titles(%{"content.sluttdato" => "$today"}, opts))

    assert Content.count_documents("arrangement", @dataset,
             filter_map: %{"title" => "$today"},
             workspace_id: :shared_only
           ) == 0
  end

  test "one process, two workspaces: each gets its own zone, never the other's" do
    [oslo, pago] =
      for zone <- ["Europe/Oslo", "Pacific/Pago_Pago"] do
        ws = create_workspace!("today-#{System.unique_integer([:positive])}")
        {:ok, _} = Tenancy.set_workspace_time_zone(ws.id, zone)
        ws
      end

    at = [now: ~U[2026-11-20 23:30:00Z]]
    # Read back to back, inside the one-second memo, and again in the other order.
    assert Content.Today.date(Content.Today.clock(oslo.id, at)) == "2026-11-21"
    assert Content.Today.date(Content.Today.clock(pago.id, at)) == "2026-11-20"
    assert Content.Today.clock(oslo.id, at).zone == "Europe/Oslo"
    assert Content.Today.clock(pago.id, at).zone == "Pacific/Pago_Pago"
  end

  test "the query API resolves $today in a filter param, as today's Studio sends it", %{
    conn: conn
  } do
    today = Date.utc_today()
    # Two days either side, so a test that crosses midnight still holds.
    events!([
      {"før", today |> Date.add(-2) |> Date.to_iso8601()},
      {"etter", today |> Date.add(2) |> Date.to_iso8601()}
    ])

    get_titles = fn op ->
      conn
      |> get("/v1/data/query/#{@dataset}/arrangement?filter[content.sluttdato][#{op}]=%24today")
      |> json_response(200)
      |> get_in(["result", "documents"])
      |> Enum.map(& &1["title"])
    end

    assert get_titles.("gte") == ["etter"]
    assert get_titles.("lt") == ["før"]
  end

  test "an API create stores today's date in the workspace time zone; no zone keeps UTC" do
    at = [now: ~U[2026-11-20 23:30:00Z]]

    create = fn zone ->
      ws = create_workspace!("today-#{System.unique_integer([:positive])}")
      project = create_project!(ws)
      if zone, do: {:ok, _} = Tenancy.set_workspace_time_zone(ws.id, zone)
      scope = [workspace_id: ws.id, project_id: project.id]
      {:ok, schema} = Content.upsert_schema(@arrangement, @dataset, scope)

      {:ok, doc} =
        Content.create_document(
          "arrangement",
          %{"doc_id" => "ny-#{ws.id}"},
          @dataset,
          scope ++ at
        )

      {schema, doc.content["publisert"]}
    end

    # 23:30 UTC is already the 21st in Oslo.
    {schema, oslo} = create.("Europe/Oslo")
    assert oslo == "2026-11-21"
    assert {_, "2026-11-20"} = create.(nil)
    # The served schema keeps the token as written.
    assert Content.Schema.serialize_schema_for_sdk(schema).initialValues == %{
             "publisert" => "$today"
           }
  end
end
