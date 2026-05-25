defmodule BarkparkWeb.Integration.V1MediaSearchSuggestionsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Search.Event
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-suggest-test",
      ["read", "write", "admin"]
    )

    Repo.delete_all(Event)
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload(name) do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "suggest-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: name,
      content_type: "image/png"
    }
  end

  defp upload_named(conn, filename) do
    created =
      conn
      |> authed()
      |> post(~p"/v1/media/production/upload", %{"file" => png_upload(filename)})
      |> json_response(201)

    on_exit(fn ->
      result = created["result"]
      File.rm(Path.join(Media.upload_dir(), result["path"]))
      Media.Renditions.delete_for_file(result["id"])
      Assets.delete_for_blob(result["id"], "production")
    end)

    created["result"]
  end

  defp search(conn, q) do
    conn =
      conn
      |> authed()
      |> maybe_commit_search()

    conn
    |> get(~p"/v1/media/production/search?q=#{q}&limit=5")
    |> json_response(200)
  end

  defp maybe_commit_search(conn) do
    case Plug.Conn.get_req_header(conn, "x-bp-search-client") do
      [_ | _] -> Plug.Conn.put_req_header(conn, "x-bp-search-record", "1")
      _ -> conn
    end
  end

  test "search records events and suggestions returns recent and popular", %{conn: conn} do
    upload_named(conn, "hero-suggest-demo.png")
    upload_named(conn, "logo-suggest-demo.png")

    search(conn, "hero-suggest")
    search(conn, "hero-suggest")
    search(conn, "hero-suggest")
    search(conn, "logo-suggest")

    suggest =
      conn
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions")
      |> json_response(200)

    recent = suggest["result"]["recent"]
    popular = suggest["result"]["popular"]

    assert length(recent) >= 2
    assert Enum.any?(recent, &(&1["query"] == "logo-suggest"))
    assert Enum.any?(popular, &(&1["query"] == "hero-suggest"))
    assert get_in(hd(popular), ["count"]) >= 3
  end

  test "search recording skipped when x-bp-search-disable header is set", %{conn: conn} do
    upload_named(conn, "disable-intel-demo.png")

    resp =
      conn
      |> put_req_header("x-bp-search-disable", "1")
      |> search("disable-intel-demo")

    assert is_nil(resp["searchEventId"])

    suggest =
      conn
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions")
      |> json_response(200)

    refute Enum.any?(suggest["result"]["recent"], &(&1["query"] == "disable-intel-demo"))
  end

  test "suggestions prefix filters popular queries", %{conn: conn} do
    upload_named(conn, "alpha-suggest.png")
    upload_named(conn, "alphabet-suggest.png")
    upload_named(conn, "beta-suggest.png")

    for q <- ["alpha", "alphabet", "beta"] do
      for _ <- 1..3, do: search(conn, q)
    end

    suggest =
      conn
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions?q=alph")
      |> json_response(200)

    popular = suggest["result"]["popular"]
    assert Enum.all?(popular, &String.starts_with?(&1["query"], "alp"))
  end

  test "zero-hit queries appear in nohits bucket", %{conn: conn} do
    search(conn, "zzznohitsquery")

    suggest =
      conn
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions")
      |> json_response(200)

    assert Enum.any?(suggest["result"]["nohits"], &(&1["query"] == "zzznohitsquery"))
  end

  test "recent is scoped to x-bp-search-client header", %{conn: conn} do
    upload_named(conn, "client-scope-demo.png")
    search(conn |> put_req_header("x-bp-search-client", "client-a"), "client-scope")
    search(conn |> put_req_header("x-bp-search-client", "client-b"), "other-query")

    suggest_a =
      conn
      |> put_req_header("x-bp-search-client", "client-a")
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions")
      |> json_response(200)

    recent_a = suggest_a["result"]["recent"]
    assert Enum.any?(recent_a, &(&1["query"] == "client-scope"))
    refute Enum.any?(recent_a, &(&1["query"] == "other-query"))

    suggest_b =
      conn
      |> put_req_header("x-bp-search-client", "client-b")
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions")
      |> json_response(200)

    recent_b = suggest_b["result"]["recent"]
    assert Enum.any?(recent_b, &(&1["query"] == "other-query"))
    refute Enum.any?(recent_b, &(&1["query"] == "client-scope"))
  end
end
