defmodule BarkparkWeb.Integration.SearchSuggestionsAudienceTest do
  @moduledoc """
  task-bee78e63628ffe9b — search suggestions must not hand one caller's query
  text to a less-privileged caller.

  `popular`/`nohits` are other people's queries. Before this fix both were
  drawn from the whole workspace's event log at every tier, so an editor's
  token search (including a `?perspective=drafts` one) was served verbatim to
  anonymous callers, and `nohits` had no floor at all — a single no-hit query
  was shown to everyone.

  (A public-read site token is the same public audience — `SearchIntel.audience/1`
  reads `AnonPerspective.anon_pinned?/1` — but the flat search routes refuse it
  outright in `PublicRead`, so it is pinned at the unit level, not here.)
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Search.Event
  alias Barkpark.Repo

  setup do
    Auth.create_token("audience-admin-token", "dev", "audience-admin", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "production"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.doc-audience-1", "title" => "Audience Phoenix Guide"},
      "production"
    )

    Content.publish_document("doc-audience-1", "post", "production")

    Repo.delete_all(from(e in Event, where: e.surface == "documents"))
    :ok
  end

  defp admin(conn), do: put_req_header(conn, "authorization", "Bearer audience-admin-token")

  defp search(conn, q, extra \\ "") do
    conn
    |> get("/v1/data/search/production?q=#{URI.encode_www_form(q)}#{extra}")
    |> json_response(200)
  end

  defp suggest(conn) do
    conn
    |> get(~p"/v1/data/search/production/suggestions")
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp queries(rows), do: Enum.map(rows, & &1["query"])

  test "an anonymous caller never sees a token caller's or a drafts search", %{conn: conn} do
    # An editor searches, repeatedly, for a real title (published and drafts
    # perspectives) and for a term with no hits — enough to clear the
    # popular/nohits count floor.
    for _ <- 1..3 do
      assert search(admin(conn), "Audience")["count"] >= 1
      search(admin(conn), "Audience", "&perspective=drafts")
      assert search(admin(conn), "editorsecretnohit")["count"] == 0
    end

    # The editor's own (private) view still has both: no over-blocking.
    private = suggest(admin(conn))
    assert "Audience" in queries(private["popular"])
    assert "editorsecretnohit" in queries(private["nohits"])

    # The anonymous view has neither.
    public = suggest(conn)
    refute "Audience" in queries(public["popular"])
    refute "editorsecretnohit" in queries(public["nohits"])
  end

  test "public callers still get suggestions built from public searches", %{conn: conn} do
    for _ <- 1..3 do
      assert search(conn, "Audience")["count"] >= 1
      search(conn, "publicnohitterm")
    end

    public = suggest(conn)
    assert "Audience" in queries(public["popular"])
    assert "publicnohitterm" in queries(public["nohits"])
  end

  test "a single no-hit query is not shown to anyone else", %{conn: conn} do
    search(conn, "onlyoncenohit")
    search(admin(conn), "onlyonceeditornohit")

    for caller <- [conn, admin(conn)] do
      result = suggest(caller)
      refute "onlyoncenohit" in queries(result["nohits"])
      refute "onlyonceeditornohit" in queries(result["nohits"])
    end
  end

  test "events are stamped with the audience that recorded them", %{conn: conn} do
    search(conn, "stampanon")
    search(admin(conn), "stampadmin")

    audience = fn q ->
      Repo.one!(
        from(e in Event,
          where: e.surface == "documents" and e.query == ^q,
          select: fragment("?->>'audience'", e.metadata)
        )
      )
    end

    assert audience.("stampanon") == "public"
    assert audience.("stampadmin") == "private"
  end
end
