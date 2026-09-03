defmodule BarkparkWeb.BulldocsSourceBpmlMetaTest do
  @moduledoc """
  The BPML source route must hand the printer the paper's LABEL SPINE.

  `Bpml.print_paper/1` has emitted `<meta><description>` + `<tag>` and the
  parser has read it back since #11640 — but `GET /papers/:slug/source` built
  its paper map from slug/title/blocks only, so both fields were absent from
  every working copy. The consequence is not cosmetic: an UNEDITED `bp paper
  pull` fails `bp paper push --check` with a `label_spine` violation claiming
  the paper has no description, on a paper that has one. 1002 of the 1015
  published papers carry both fields.

  This is the transport half of the round-trip property; the printer half lives
  in `Barkpark.PortableDoc.BpmlRoundtripPropertyTest`. A serializer cannot
  round-trip a field it was never handed, so the request is tested here rather
  than blamed on the encoder.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp publish!(slug) do
    bpml = """
    <paper slug="#{slug}" title="Label spine">
      <h1>Label spine</h1>
      <p id="p1">The body is beside the point here; the meta is the subject.</p>
    </paper>
    """

    body = LabelFixtures.paper_attrs(%{"bpml" => bpml})
    assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)
    Content.get_paper(slug)
  end

  test "the pulled BPML carries description and the weighted tags", %{conn: conn} do
    slug = "bpml-meta-spine-paper"
    paper = publish!(slug)

    description = get_in(paper.content, ["description"])
    tags = get_in(paper.content, ["tags"])

    # Guard the fixture itself: if the paper under test has no label spine the
    # assertions below would pass vacuously.
    assert is_binary(description) and description != ""
    assert is_list(tags) and tags != []

    bpml =
      conn
      |> get("/papers/#{slug}/source", %{"format" => "bpml"})
      |> response(200)

    assert bpml =~ "<meta>"
    assert bpml =~ "<description>"

    assert {:ok, parsed} = Bpml.parse_paper(bpml)

    assert parsed["description"] == description,
           """
           The working copy lost the paper's description, so `bp paper push --check`
           answers a FALSE label_spine violation on an UNEDITED pull.

           stored: #{inspect(description)}
           pulled: #{inspect(parsed["description"])}
           """

    assert parsed["tags"] == tags,
           """
           The working copy lost the paper's weighted tags.

           stored: #{inspect(tags)}
           pulled: #{inspect(parsed["tags"])}
           """
  end

  # A spine-less paper cannot be BORN — the publish wall rejects it (that
  # rejection is asserted below so this test cannot rot into a vacuous pass).
  # It can only EXIST as a grandfathered row predating the wall, which the wall
  # lets through unchanged. That is the shape the nil-description path has to
  # survive, so the fixture strips the spine after publish rather than
  # pretending the ingest route would accept one without it.
  test "a grandfathered paper with no label spine emits no empty <meta> block", %{conn: conn} do
    slug = "bpml-meta-absent-paper"

    bpml_in = """
    <paper slug="#{slug}" title="Spineless">
      <p id="p1">No description, no tags.</p>
    </paper>
    """

    # The wall refuses a BIRTH without a spine — pinned, so the strip below is
    # understood as modelling a grandfathered row and not as a shortcut.
    assert authed(build_conn())
           |> post(@ingest_path, %{"bpml" => bpml_in, "description" => nil, "tags" => []})
           |> json_response(422)

    paper = publish!(slug)

    {:ok, _} =
      paper
      |> Ecto.Changeset.change(content: Map.drop(paper.content, ["description", "tags"]))
      |> Barkpark.Repo.update()

    stripped = Content.get_paper(slug)
    refute Map.has_key?(stripped.content, "description")
    refute Map.has_key?(stripped.content, "tags")

    bpml =
      conn
      |> get("/papers/#{slug}/source", %{"format" => "bpml"})
      |> response(200)

    refute bpml =~ "<meta>"
    assert {:ok, parsed} = Bpml.parse_paper(bpml)
    refute Map.has_key?(parsed, "description")
    refute Map.has_key?(parsed, "tags")
  end
end
