defmodule BarkparkWeb.Integration.V1MediaSearchInsightsTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Search.{Crystallizer, Event}
  alias Barkpark.Repo

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-insights-test",
      ["read", "write", "admin"]
    )

    Repo.delete_all(Event)
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  test "insights returns crystals, merge patterns, and quality stats", %{conn: conn} do
    day = Date.add(Date.utc_today(), -1)
    at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

    {:ok, a} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: "media",
        scope: "production",
        query: "campaign",
        query_normalized: "campaign",
        filters: %{},
        result_count: 0,
        zero_hits: true,
        actor_key: "actor-1",
        inserted_at: at
      })
      |> Repo.insert()

    {:ok, _b} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: "media",
        scope: "production",
        query: "campaign",
        query_normalized: "campaign",
        filters: %{"kind" => "image"},
        result_count: 5,
        zero_hits: false,
        actor_key: "actor-1",
        parent_event_id: a.id,
        inserted_at: DateTime.add(at, 90, :second)
      })
      |> Repo.insert()

    Crystallizer.crystallize_period("media", "production", :day, day)

    resp =
      conn
      |> authed()
      |> get(
        ~p"/v1/media/production/search/insights?period=day&periodStart=#{Date.to_iso8601(day)}"
      )
      |> json_response(200)

    result = resp["result"]
    assert result["period"] == "day"
    assert result["surface"] == "media"
    assert result["scope"] == "production"
    assert is_list(result["topQueries"])
    assert is_list(result["mergePatterns"])
    assert is_list(result["hints"])
    assert is_map(result["quality"])
  end

  test "rejects profanity in analytics without storing bad text", %{conn: conn} do
    conn
    |> authed()
    |> get(~p"/v1/media/production/search?q=fuck&limit=5")
    |> json_response(200)

    refute Repo.one(from(e in Event, where: ilike(e.query, "%fuck%")))
    assert Repo.get_by(Event, quality: "rejected", reject_reason: "profanity")
  end

  test "insights defaults periodStart when omitted", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> get(~p"/v1/media/production/search/insights?period=week")
      |> json_response(200)

    result = resp["result"]
    assert result["period"] == "week"
    assert result["periodStart"] != nil
    assert result["surface"] == "media"
  end
end
