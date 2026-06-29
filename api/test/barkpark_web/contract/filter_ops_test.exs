defmodule BarkparkWeb.Contract.FilterOpsTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "fops_http"
    )

    for {id, title} <- [{"f1", "Alpha"}, {"f2", "Beta"}, {"f3", "Gamma"}] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, "fops_http")
      {:ok, _} = Content.publish_document(id, "post", "fops_http")
    end

    :ok
  end

  test "filter[title][eq]=Alpha matches one", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Beq%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "Alpha"
  end

  test "filter[title][in]=Alpha,Gamma matches two", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bin%5D=Alpha,Gamma")
      |> json_response(200)

    assert body["count"] == 2
    titles = Enum.map(body["documents"], & &1["title"]) |> Enum.sort()
    assert titles == ["Alpha", "Gamma"]
  end

  test "filter[title][contains]=a is case-insensitive", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bcontains%5D=a")
      |> json_response(200)

    assert body["count"] == 3
  end

  test "bare filter[title]=Alpha still works (sugar for eq)", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
  end

  test "scalar `field is null` / `is not null` filter (CLI/raw-API form)", %{conn: conn} do
    # f1/f2/f3 have no `category`; f4 does.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "f4", "title" => "Delta", "category" => "x"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("f4", "post", "fops_http")

    is_null =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("category is null")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(is_null["documents"], & &1["title"]) |> Enum.sort() ==
             ["Alpha", "Beta", "Gamma"]

    is_not_null =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("category is not null")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(is_not_null["documents"], & &1["title"]) == ["Delta"]
  end

  test "scalar `^=` (startsWith) / `$=` (endsWith) shorthands", %{conn: conn} do
    # f1 Alpha, f2 Beta, f3 Gamma
    starts =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title^=Al")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(starts["documents"], & &1["title"]) == ["Alpha"]

    ends =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title$=ma")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(ends["documents"], & &1["title"]) == ["Gamma"]
  end

  test "scalar `*=` (contains) shorthand — substring, case-insensitive", %{conn: conn} do
    # f1 Alpha, f2 Beta, f3 Gamma all contain "a" (case-insensitive)
    all_a =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title*=A")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(all_a["documents"], & &1["title"]) |> Enum.sort() == [
             "Alpha",
             "Beta",
             "Gamma"
           ]

    # "et" is a mid-string substring of only Beta
    et =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title*=et")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(et["documents"], & &1["title"]) == ["Beta"]
  end

  test "scalar `in` / `not in` membership (comma list)", %{conn: conn} do
    in_ =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title in Alpha,Gamma")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(in_["documents"], & &1["title"]) |> Enum.sort() == ["Alpha", "Gamma"]

    not_in =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title not in Alpha,Gamma")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(not_in["documents"], & &1["title"]) == ["Beta"]
  end

  test "an operator value containing ` in ` is NOT misread as an `in` filter", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "f9", "title" => "logged in user"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("f9", "post", "fops_http")

    # `title=logged in user` → eq on the whole value (operator wins over the ` in ` keyword)
    body =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title=logged in user")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(body["documents"], & &1["title"]) == ["logged in user"]
  end

  test "?fields= projects to the named content fields (plus system fields)", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "proj1", "title" => "Projected", "body" => "secret body", "slug" => "proj-1"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("proj1", "post", "fops_http")

    doc =
      conn
      |> get(
        "/v1/data/query/fops_http/post" <>
          "?filter=#{URI.encode_www_form("title=Projected")}&fields=title,slug"
      )
      |> json_response(200)
      |> Map.fetch!("result")
      |> Map.fetch!("documents")
      |> hd()

    # selected content fields present
    assert doc["title"] == "Projected"
    assert doc["slug"] == "proj-1"
    # unselected content field dropped
    refute Map.has_key?(doc, "body")
    # system fields always kept
    assert doc["_id"]
    assert doc["_type"] == "post"
  end

  test "multi-field order — comma-separated specs sort by primary then secondary", %{conn: conn} do
    for {id, rank, title} <- [{"m1", 1, "Zeta"}, {"m2", 1, "Alpha"}, {"m3", 2, "Mid"}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => title, "rank" => rank},
          "fops_http"
        )

      {:ok, _} = Content.publish_document(id, "post", "fops_http")
    end

    # `rank is not null` scopes to m1/m2/m3 (Alpha/Beta/Gamma have no rank).
    body =
      conn
      |> get(
        "/v1/data/query/fops_http/post" <>
          "?filter=#{URI.encode_www_form("rank is not null")}" <>
          "&order=#{URI.encode_www_form("rank:asc,title:asc")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    # rank 1 (Alpha < Zeta by title), then rank 2 (Mid). Without the title
    # tiebreak the Alpha/Zeta order within rank 1 would be undefined.
    assert Enum.map(body["documents"], & &1["title"]) == ["Alpha", "Zeta", "Mid"]
  end
end
