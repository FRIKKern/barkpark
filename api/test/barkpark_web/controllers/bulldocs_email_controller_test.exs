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

  # The ingest omits `dataset`, so upsert_paper lands the paper in Content's
  # @paper_default_dataset ("production") — register the wall tags there.
  @dataset "production"

  # Publish-wall labels (charter D26/D39): the paper-birth ingest ENFORCES the
  # wall, so a compliant POST must carry registered weighted tags + a
  # description. Distinct strengths, unique max, rationales ≥20 chars.
  @wall_tag_names ~w(email-proof-deck email-proof-inline email-proof-snapshot)
  @wall_tags [
    %{
      "tag" => "email-proof-deck",
      "strength" => 89,
      "rationale" => "Primary label: the full-deck email-view fixture paper."
    },
    %{
      "tag" => "email-proof-inline",
      "strength" => 54,
      "rationale" => "Secondary label: inline-styled email render coverage."
    },
    %{
      "tag" => "email-proof-snapshot",
      "strength" => 23,
      "rationale" => "Tertiary label: pinned task-snapshot email fixture."
    }
  ]
  @wall_description "Email-view fixture paper: full block deck mailed through the wall."

  setup do
    # The publish wall (E3) rejects unknown tags — register the payload's tags.
    Barkpark.LabelFixtures.register_tags!(@dataset, @wall_tag_names)
    :ok
  end

  defp ingest!(conn, slug) do
    body = %{
      "slug" => slug,
      "title" => "Email view fixture",
      "tags" => @wall_tags,
      "description" => @wall_description,
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

  test "legacy body_html is sanitized and mailed instead of a blank shell", %{conn: conn} do
    slug = "legacy-html-email"

    {:ok, _paper} =
      Barkpark.Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "body_html" => "<h1>Legacy is readable</h1><script>alert('no')</script>"
        })
      )

    html = conn |> get("/papers/#{slug}/email") |> response(200)
    assert html =~ "Legacy is readable"
    refute html =~ "<script"
    refute html =~ "alert('no')"

    source =
      conn
      |> put_req_header("accept", "*/*")
      |> get("/papers/#{slug}/source")
      |> json_response(200)
      |> get_in(["source"])

    assert source["kind"] == "html"
    assert source["html"] =~ "Legacy is readable"
    refute source["html"] =~ "<script"
  end
end
