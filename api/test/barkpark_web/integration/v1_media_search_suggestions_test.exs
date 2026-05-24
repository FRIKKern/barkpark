defmodule BarkparkWeb.Integration.V1MediaSearchSuggestionsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Media.SearchEvent
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

    Repo.delete_all(SearchEvent)
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
    conn
    |> authed()
    |> get(~p"/v1/media/production/search?q=#{q}&limit=5")
    |> json_response(200)
  end

  test "search records events and suggestions returns recent and popular", %{conn: conn} do
    upload_named(conn, "hero-suggest-demo.png")
    upload_named(conn, "logo-suggest-demo.png")

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
    assert get_in(hd(popular), ["count"]) >= 2
  end

  test "suggestions prefix filters popular queries", %{conn: conn} do
    upload_named(conn, "alpha-suggest.png")
    upload_named(conn, "alphabet-suggest.png")
    upload_named(conn, "beta-suggest.png")

    for q <- ["alpha", "alphabet", "beta"] do
      search(conn, q)
    end

    suggest =
      conn
      |> authed()
      |> get(~p"/v1/media/production/search/suggestions?q=alp")
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
end
