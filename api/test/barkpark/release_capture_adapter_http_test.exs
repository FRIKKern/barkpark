defmodule Barkpark.CycleFleet.ReleaseCaptureAdapterHTTPTest do
  use ExUnit.Case, async: true

  alias Barkpark.CycleFleet.ReleaseCaptureAdapter.BoundedHTTP

  test "streams a bounded response and preserves response metadata" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/paper", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
      |> Plug.Conn.put_resp_header("etag", ~s("sha256:test"))
      |> Plug.Conn.resp(200, "paper")
    end)

    assert {:ok, 200, headers, "paper"} =
             BoundedHTTP.get(url(bypass, "/paper"), [],
               body_limit: 32,
               expected_content_type: "text/html"
             )

    assert headers["etag"] == [~s("sha256:test")]
  end

  test "halts the stream as soon as the body exceeds its hard limit" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/oversize", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, String.duplicate("x", 65))
    end)

    assert {:error, :response_body_too_large} =
             BoundedHTTP.get(url(bypass, "/oversize"), [],
               body_limit: 64,
               expected_content_type: "application/json"
             )
  end

  test "does not follow redirects" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/redirect", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", url(bypass, "/must-not-be-read"))
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(302, "redirect")
    end)

    assert {:ok, 302, _headers, "redirect"} =
             BoundedHTTP.get(url(bypass, "/redirect"), [], expected_content_type: "text/html")
  end

  test "rejects a response with the wrong content type" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/wrong-type", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, "not json")
    end)

    assert {:error, :invalid_content_type} =
             BoundedHTTP.get(url(bypass, "/wrong-type"), [],
               expected_content_type: "application/json"
             )
  end

  defp url(bypass, path), do: "http://127.0.0.1:#{bypass.port}#{path}"
end
