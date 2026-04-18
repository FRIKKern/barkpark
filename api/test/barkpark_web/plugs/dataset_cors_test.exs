defmodule BarkparkWeb.Plugs.DatasetCorsTest do
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias BarkparkWeb.Plugs.DatasetCors

  defp conn_for(dataset, origin \\ nil) do
    conn = build_conn(:get, "/v1/data/query/#{dataset}/post")
    conn = %{conn | path_params: %{"dataset" => dataset}}
    if origin, do: put_req_header(conn, "origin", origin), else: conn
  end

  defp put_schema(dataset, name, cors_origins) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "cors_origins" => cors_origins},
        dataset
      )
  end

  test "no Origin header → passthrough" do
    put_schema("ds_none", "post", ["https://only.example.com"])

    conn = conn_for("ds_none") |> DatasetCors.call(DatasetCors.init([]))

    refute conn.halted
  end

  test "empty allow-list → passthrough (default-allow)" do
    put_schema("ds_empty", "post", [])

    conn =
      conn_for("ds_empty", "https://random.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    refute conn.halted
  end

  test "wildcard allow-list → passthrough for any origin" do
    put_schema("ds_wild", "post", ["*"])

    conn =
      conn_for("ds_wild", "https://anywhere.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    refute conn.halted
  end

  test "specific allow-list, matching origin → passthrough" do
    put_schema("ds_match", "post", ["https://ok.example.com"])

    conn =
      conn_for("ds_match", "https://ok.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    refute conn.halted
  end

  test "specific allow-list, non-matching origin → 403 envelope" do
    put_schema("ds_deny", "post", ["https://allowed.example.com"])

    conn =
      conn_for("ds_deny", "https://evil.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    assert conn.halted
    assert conn.status == 403

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "cors_forbidden"
    assert body["error"]["message"] =~ "origin not allowed"
  end

  test "no dataset path param → passthrough (not our business)" do
    conn = build_conn(:get, "/") |> DatasetCors.call(DatasetCors.init([]))

    refute conn.halted
  end

  test "union across multiple schemas in dataset" do
    put_schema("ds_union", "post", ["https://a.example.com"])
    put_schema("ds_union", "page", ["https://b.example.com"])

    conn_a =
      conn_for("ds_union", "https://a.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    conn_b =
      conn_for("ds_union", "https://b.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    conn_c =
      conn_for("ds_union", "https://c.example.com")
      |> DatasetCors.call(DatasetCors.init([]))

    refute conn_a.halted
    refute conn_b.halted
    assert conn_c.halted
    assert conn_c.status == 403
  end
end
