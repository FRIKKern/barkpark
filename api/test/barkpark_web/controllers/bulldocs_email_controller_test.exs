defmodule BarkparkWeb.BulldocsEmailControllerTest do
  @moduledoc """
  `GET /papers/:slug/email` — the paper as the exact email byte stream.

  Ingests a published paper carrying prose, a toned callout and a pinned task
  snapshot, then asserts the email route serves a COMPLETE standalone document
  (doctype + centered card), inline-styled in the evergreen email palette,
  with the paper's content rendered through the `:email` style. Unknown slug
  is a plain 404 (same visibility contract as the reader).
  """
  use BarkparkWeb.ConnCase, async: false

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"

  defp ingest!(conn, slug) do
    body = %{
      "slug" => slug,
      "title" => "Email view fixture",
      "blocks" => [
        %{"type" => "heading", "level" => 1, "text" => "The full deck, mailed"},
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Every component, inline-styled."}]
        },
        %{
          "type" => "callout",
          "tone" => "success",
          "content" => [%{"type" => "text", "value" => "The gate is green."}]
        },
        %{
          "type" => "task-list",
          "snapshot" => [%{"title" => "ship the email view", "status" => "done"}]
        }
      ]
    }

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> @token)
    |> post("/v1/plugins/bulldocs/papers", body)
    |> json_response(200)
  end

  test "serves the evergreen email document for a published paper", %{conn: conn} do
    ingest!(conn, "email-view-fixture")

    conn = get(build_conn(), "/papers/email-view-fixture/email")
    assert response_content_type(conn, :html)
    html = response(conn, 200)

    # A COMPLETE standalone document with the email envelope.
    assert String.starts_with?(html, "<!doctype html>")
    assert html =~ ~s(max-width:600px)

    # The evergreen profile, inline (email clients strip <style>).
    assert html =~ "#eaf1ee"
    assert html =~ "#1e5347" or html =~ "#15211d"
    refute html =~ "<style"
    refute html =~ "#4f46e5"

    # Content + the harmonized success tint + the pinned snapshot.
    assert html =~ "The full deck, mailed"
    assert html =~ "#e7f2ec"
    assert html =~ "ship the email view"
  end

  test "unknown slug is a plain 404", %{conn: conn} do
    conn = get(conn, "/papers/definitely-not-a-paper/email")
    assert response(conn, 404)
  end
end
