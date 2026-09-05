defmodule BarkparkWeb.BulldocsEmailControllerTest do
  @moduledoc """
  `GET /papers/:slug/email` — the paper as the exact email byte stream.

  Ingests a published paper carrying prose, a toned callout and a pinned task
  snapshot, then asserts the email route serves a COMPLETE standalone document
  (doctype + centered card), inline-styled in the evergreen email palette,
  with the paper's content rendered through the `:email` style. Unknown slug
  is a plain 404 (same visibility contract as the reader).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Content, Repo}

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

  defp ingest!(conn, slug, overrides \\ %{}) do
    body =
      %{
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
            "type" => "list",
            "items" => [
              [%{"type" => "text", "value" => "First semantic bullet"}],
              [%{"type" => "text", "value" => "Second semantic bullet"}]
            ]
          },
          %{
            "type" => "list",
            "ordered" => true,
            "items" => [
              [%{"type" => "text", "value" => "First semantic step"}],
              [%{"type" => "text", "value" => "Second semantic step"}]
            ]
          },
          %{
            "type" => "task-list",
            "snapshot" => [%{"title" => "ship the email view", "status" => "done"}]
          }
        ]
      }
      |> Map.merge(overrides)

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

    # Canonical PortableDoc lists retain semantic structure in the actual email
    # endpoint, rather than degrading to presentation-only flex rows.
    assert html =~ "<ul"
    assert html =~ "<ol"
    assert length(Regex.scan(~r/<li(?:\s|>)/, html)) == 4
    assert html =~ "First semantic bullet"
    assert html =~ "First semantic step"
    refute html =~ "• "
    refute html =~ "flex-direction"
  end

  test "unknown slug is a plain 404", %{conn: conn} do
    conn = get(conn, "/papers/definitely-not-a-paper/email")
    assert response(conn, 404)
  end

  test "conflicting canonical sources fail closed instead of mailing either version", %{
    conn: conn
  } do
    slug = "email-ambiguous-source-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Canonical blocks"}]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", "<p>conflict</p>"))
    |> Repo.update!()

    assert %{"error" => %{"code" => "ambiguous_source"}} =
             conn
             |> get("/papers/#{slug}/email")
             |> json_response(422)
  end

  test "legacy body_html is sanitized and mailed instead of a blank shell", %{conn: conn} do
    slug = "legacy-html-email"

    {:ok, _paper} =
      Barkpark.Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "body_html" =>
            "<h1>Legacy is readable</h1><a href=\"./next\">Next</a><script>alert('no')</script>"
        })
      )

    html = conn |> get("/papers/#{slug}/email") |> response(200)
    assert html =~ "Legacy is readable"
    assert html =~ ~s(href="#{BarkparkWeb.Endpoint.url()}/papers/next")
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

  test "email-only link policy absolutizes internal links and strips unsafe schemes", %{
    conn: conn
  } do
    blocks = [
      %{"type" => "heading", "level" => 2, "text" => "Links"},
      %{
        "type" => "paragraph",
        "content" => [
          %{"type" => "link", "href" => "./related", "children" => ["related"]},
          %{"type" => "link", "href" => "/papers/rooted", "children" => ["rooted"]},
          %{"type" => "link", "href" => "#details", "children" => ["fragment"]},
          %{
            "type" => "link",
            "href" => "https://example.com/x?a=1&b=2",
            "children" => ["absolute"]
          },
          %{"type" => "link", "href" => "javascript:alert(1)", "children" => ["unsafe"]}
        ]
      }
    ]

    ingest!(conn, "email-link-policy", %{"blocks" => blocks})
    html = build_conn() |> get("/papers/email-link-policy/email") |> response(200)
    origin = BarkparkWeb.Endpoint.url()

    assert html =~ ~s(href="#{origin}/papers/related")
    assert html =~ ~s(href="#{origin}/papers/rooted")
    assert html =~ ~s(href="#details")
    assert html =~ ~s(href="https://example.com/x?a=1&amp;b=2")
    refute html =~ "javascript:"
    assert html =~ ~r/<a style="[^"]+">unsafe<\/a>/
  end

  test "one fallback h1 names headingless email content", %{} do
    {:ok, _paper} =
      Barkpark.Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "email-accessible-name",
          "dataset" => @dataset,
          "blocks" => [%{"type" => "paragraph", "content" => ["Body only"]}]
        })
      )

    html = build_conn() |> get("/papers/email-accessible-name/email") |> response(200)

    assert html =~ "<title>email-accessible-name</title>"
    assert length(Regex.scan(~r/<h1(?:\s|>)/i, html)) == 1
    assert html =~ ">email-accessible-name</h1>"
  end

  test "authored heading suppresses fallback h1 and supplies an escaped title", %{conn: conn} do
    ingest!(conn, "email-authored-heading", %{
      "blocks" => [
        %{"type" => "heading", "level" => 2, "text" => ~s(Quarterly <&> "Report")},
        %{"type" => "paragraph", "content" => ["Body."]}
      ]
    })

    html = build_conn() |> get("/papers/email-authored-heading/email") |> response(200)

    assert html =~ "<title>Quarterly &lt;&amp;&gt; &quot;Report&quot;</title>"
    assert html =~ "<h2"
    refute html =~ ~r/<h1(?:\s|>)/i
  end

  test "email finalizer resolves against its explicit trusted scoped reader URI", %{} do
    html =
      ~s(<!doctype html><html><head><meta charset="utf-8"></head><body><a href="./sibling">Sibling</a><a href="//evil.example/x">Unsafe</a></body></html>)

    trusted_reader = URI.parse("https://trusted.example/w/acme/p/docs/papers/current")

    rendered =
      BarkparkWeb.BulldocsEmailHTML.finalize(html, ~s(Name <&> "safe"), trusted_reader)

    assert rendered =~ "<title>Name &lt;&amp;&gt; &quot;safe&quot;</title>"

    assert rendered =~
             ~s(href="https://trusted.example/w/acme/p/docs/papers/sibling")

    refute rendered =~ "evil.example"
    assert rendered =~ "<a>Unsafe</a>"
  end

  # `dataset` is query-string sourced on `/papers/:slug/email` (and on its
  # scoped `/w/:ws/p/:project` twin) — only `/d/:dataset/papers/:slug/...`
  # carries it as a path segment. Plug decodes `?dataset[]=x` to a LIST and
  # `?dataset[a]=b` to a MAP, and either one reaching `x.dataset == ^dataset`
  # on a :string column raises Ecto.Query.CastError. Nothing implements
  # Plug.Exception for that struct, so it escaped as a raw 500 where the paper
  # is simply not found. These three lock the guard in both controllers: the
  # malformed selector fails soft to the default dataset (404 here, because the
  # fixture paper lives elsewhere) while a real binary selector is still honored.
  @other_dataset "staging"

  defp paper_in_other_dataset! do
    slug = "dataset-cast-guard-#{System.unique_integer([:positive])}"
    Barkpark.LabelFixtures.register_tags!(@other_dataset)

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @other_dataset,
          "blocks" => [%{"type" => "paragraph", "content" => ["Only in staging."]}]
        })
      )

    slug
  end

  test "a list-valued ?dataset[]= is 404, not an Ecto.Query.CastError 500", %{conn: conn} do
    slug = paper_in_other_dataset!()

    # The honest selector finds it...
    assert conn |> get("/papers/#{slug}/email?dataset=#{@other_dataset}") |> response(200) =~
             "Only in staging."

    # ...the malformed one falls back to the default dataset and 404s.
    assert build_conn()
           |> get("/papers/#{slug}/email?dataset[]=#{@other_dataset}")
           |> response(404)

    assert build_conn()
           |> put_req_header("accept", "*/*")
           |> get("/papers/#{slug}/source?dataset[]=#{@other_dataset}")
           |> response(404)
  end

  test "a map-valued ?dataset[k]= is 404, not an Ecto.Query.CastError 500", %{conn: conn} do
    slug = paper_in_other_dataset!()

    assert conn |> get("/papers/#{slug}/email?dataset[a]=b") |> response(404)

    assert build_conn()
           |> put_req_header("accept", "*/*")
           |> get("/papers/#{slug}/source?dataset[a]=b")
           |> response(404)
  end

  test "a binary ?dataset= still selects that dataset on the source route", %{conn: conn} do
    slug = paper_in_other_dataset!()

    assert %{"source" => %{"kind" => "blocks"}} =
             conn
             |> put_req_header("accept", "*/*")
             |> get("/papers/#{slug}/source?dataset=#{@other_dataset}")
             |> json_response(200)
  end

  test "email finalizer normalizes sanitizer-valid spaced and bare href grammar", %{} do
    html =
      ~s(<!doctype html><html><head><meta charset="utf-8"></head><body><a href = "./quoted">Quoted</a><a href=./bare>Bare</a><a href = "//evil.example/x">Unsafe</a></body></html>)

    trusted_reader = URI.parse("https://trusted.example/papers/current")
    rendered = BarkparkWeb.BulldocsEmailHTML.finalize(html, "Links", trusted_reader)

    assert rendered =~ ~s(href="https://trusted.example/papers/quoted")
    assert rendered =~ ~s(href="https://trusted.example/papers/bare")
    refute rendered =~ "evil.example"
    assert rendered =~ "<a>Unsafe</a>"
  end
end
