defmodule BarkparkWeb.Studio.ReferenceFilterTest do
  @moduledoc """
  task-281dfb5b6e350517: a reference field declares Sanity's `options.filter`
  (GROQ) and `options.filterParams`. The schema apply refuses GROQ that does not
  parse, the Studio editor hands the picker the filter and the parameters read
  from the open document, and the GROQ the picker sends keeps only the matching
  candidates.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.ReferenceFilter
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  @event_schema %{
    "name" => "event",
    "title" => "Arrangement",
    "visibility" => "public",
    "fields" => [
      %{"name" => "title", "title" => "Tittel", "type" => "string"},
      %{"name" => "isSeriesParent", "title" => "Hovedarrangement?", "type" => "boolean"},
      %{
        "name" => "parentEvent",
        "title" => "Hovedarrangement",
        "type" => "reference",
        "to" => [%{"type" => "event"}],
        "options" => %{
          "filter" => "isSeriesParent == true && _id != $self",
          "filterParams" => %{"self" => %{"fromDocument" => "_id"}}
        }
      },
      %{
        "name" => "related",
        "title" => "Relaterte",
        "type" => "arrayOf",
        "of" => %{
          "type" => "reference",
          "refType" => "event",
          "options" => %{
            "filter" => "isSeriesParent != $flag",
            "filterParams" => %{"flag" => true}
          }
        }
      }
    ]
  }

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "rf-twin-#{suffix}", name: "Filter Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "rf-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "rf-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} = Content.upsert_schema(@event_schema, @dataset, scope)

    for {id, title, parent?} <- [
          {"ev-parent", "Litteraturfestivalen", true},
          {"ev-child", "Litteraturfestivalen: dag 1", false},
          {"ev-open", "Bokhøst", true}
        ] do
      {:ok, _} =
        Content.upsert_document(
          "event",
          %{
            "doc_id" => id,
            "title" => title,
            "content" => %{"title" => title, "isSeriesParent" => parent?}
          },
          @dataset,
          Keyword.put(scope, :source, :api)
        )

      {:ok, _} = Content.publish_document(id, "event", @dataset, scope)
    end

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope, token: raw}
  end

  test "the editor hands each picker its filter and the parameters from the open document", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/event/ev-open")

    doc = LazyHTML.from_fragment(html)

    [picker] =
      doc
      |> LazyHTML.query(~s(bp-reference-picker[filter="isSeriesParent == true && _id != $self"]))
      |> Enum.to_list()

    assert picker |> LazyHTML.attribute("ref-type") == ["event"]

    [wrap] =
      doc
      |> LazyHTML.query(~s([id^="bp-ref-wrap-parentEvent"]))
      |> Enum.to_list()

    assert wrap |> LazyHTML.attribute("data-filter-params") |> hd() |> Jason.decode!() ==
             %{"self" => "ev-open"}
  end

  test "the picker's GROQ keeps only the candidates the filter matches", %{
    conn: conn,
    ws: ws,
    proj: proj,
    token: token
  } do
    query =
      "*[_id in $#{ReferenceFilter.candidates_param()} && (isSeriesParent == true && _id != $self)]._id"

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/w/#{ws.slug}/p/#{proj.slug}/v2025-02-19/data/query/#{@dataset}", %{
        "query" => query,
        "perspective" => "raw",
        "$bpCandidateIds" => Jason.encode!(["ev-parent", "ev-child", "ev-open"]),
        "$self" => Jason.encode!("ev-open")
      })
      |> json_response(200)

    assert body["result"] == ["ev-parent"]
  end

  test "a schema whose filter does not parse is refused", %{scope: scope} do
    bad =
      put_in(
        @event_schema,
        ["fields", Access.at(2), "options", "filter"],
        "isSeriesParent == == true"
      )

    assert {:error, changeset} = Content.upsert_schema(bad, @dataset, scope)
    assert inspect(changeset.errors) =~ "parentEvent: options.filter is not valid GROQ"

    missing_param =
      put_in(@event_schema, ["fields", Access.at(3), "of", "options", "filterParams"], %{})

    assert {:error, changeset} = Content.upsert_schema(missing_param, @dataset, scope)
    assert inspect(changeset.errors) =~ "related.of: options.filter is not valid GROQ"

    not_string = put_in(@event_schema, ["fields", Access.at(2), "options", "filter"], 42)
    assert {:error, changeset} = Content.upsert_schema(not_string, @dataset, scope)
    assert inspect(changeset.errors) =~ "options.filter must be a GROQ string"
  end

  describe "ReferenceFilter" do
    test "of/1 reads options.filter, and params/3 reads fromDocument values" do
      field = Enum.at(@event_schema["fields"], 2)

      assert %{filter: "isSeriesParent == true && _id != $self", params: spec} =
               ReferenceFilter.of(field)

      assert ReferenceFilter.params(spec, %{}, "drafts.ev-open") == %{"self" => "ev-open"}

      spec = %{"cat" => %{"fromDocument" => "category"}, "n" => 2}

      assert ReferenceFilter.params(spec, %{"category" => %{"_ref" => "cat-1"}}, nil) ==
               %{"cat" => "cat-1", "n" => 2}

      assert ReferenceFilter.of(%{"type" => "reference"}) == nil
      assert ReferenceFilter.of(%{"options" => %{"filter" => "  "}}) == nil
    end
  end
end
