defmodule BarkparkWeb.BulldocsPaperRevAnchorTest do
  @moduledoc """
  The BPML working-copy rev anchor, read by ONE owner on BOTH sides.

  `GET /papers/:slug/source?format=bpml` stamps `x-paper-rev`; `POST
  …/:slug/sync` compares `baseRev` against it. They used to derive it apart and
  disagree for a paper carrying no integer `content["rev"]`: pull fell back to
  the row's opaque `rev` HASH, push coerced the absence to `""`, and the refusal
  read `paper is at rev , your copy anchored on <hash>` — a 412 whose
  server-side comparand was EMPTY, on a paper that had not moved. Pull handed
  back the same hash every time, so the refusal was unrecoverable.

  Both sides now read `Content.Papers.op_rev/1`.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp bpml_doc(slug, body) do
    """
    <paper slug="#{slug}" title="Anchor">
      <h1>Anchor</h1>
      <section id="s1" title="Detail">
        <p id="p1">#{body}</p>
      </section>
    </paper>
    """
  end

  defp publish!(slug, body \\ "unchanged") do
    assert authed(build_conn())
           |> post(@ingest_path, LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug, body)}))
           |> json_response(200)

    Content.get_paper(slug)
  end

  # Rewrite content["rev"] out from under the paper. `put` with :remove drops
  # the key entirely (the revless shape); any other value is written verbatim.
  defp set_content_rev(paper, :remove), do: write_content(paper, Map.delete(paper.content, "rev"))

  defp set_content_rev(paper, value),
    do: write_content(paper, Map.put(paper.content, "rev", value))

  defp write_content(paper, content) do
    paper
    |> Ecto.Changeset.change(%{content: content})
    |> Repo.update!()
  end

  defp pull(conn, slug) do
    get(conn, "/papers/#{slug}/source", %{"format" => "bpml"})
  end

  describe "a revless paper (no integer content[\"rev\"])" do
    test "pulls an anchor of 0 and pushes straight back unchanged — the 412 reproduction",
         %{conn: conn} do
      slug = "rev-anchor-revless"
      publish!(slug) |> set_content_rev(:remove)

      # PULL — the request and the anchor it hands out.
      pulled = pull(conn, slug)
      assert [anchor] = get_resp_header(pulled, "x-paper-rev")
      bpml = response(pulled, 200)

      # PUSH — byte-identical document, on the anchor pull just served. This is
      # the assertion that reds on the unfixed server with
      #   412 {"code":"precondition_failed",
      #        "message":"paper is at rev , your copy anchored on <row hash>"}
      pushed =
        authed(build_conn())
        |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => anchor})

      body = json_response(pushed, 200)
      assert body["ok"] == true
      assert body["unchanged"] == true
      assert body["op_count"] == 0

      # and the anchor is the integer the enforcement layer reads, not a hash
      assert anchor == "0"
    end

    test "applies a real edit at that anchor — the if_rev guard accepts it too", %{conn: conn} do
      slug = "rev-anchor-revless-edit"
      publish!(slug) |> set_content_rev(:remove)

      pulled = pull(conn, slug)
      assert [anchor] = get_resp_header(pulled, "x-paper-rev")

      edited = String.replace(response(pulled, 200), "unchanged", "moved on")

      pushed =
        authed(build_conn())
        |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => edited, "baseRev" => anchor})

      body = json_response(pushed, 200)
      assert body["ok"] == true
      assert body["op_count"] > 0
    end
  end

  describe "the precondition never compares against a failed read" do
    test "an unreadable content[\"rev\"] is a distinct CANNOT READ refusal on push",
         %{conn: _conn} do
      slug = "rev-anchor-unreadable-push"
      publish!(slug) |> set_content_rev("not-an-integer")

      pushed =
        authed(build_conn())
        |> post("#{@ingest_path}/#{slug}/sync", %{
          "bpml" => bpml_doc(slug, "unchanged"),
          "baseRev" => "1"
        })

      assert %{"error" => err} = json_response(pushed, 422)
      assert err["code"] == "paper_rev_unreadable"
      # names the doc and the field, and is NOT spelled as a mismatch
      assert err["message"] =~ slug
      assert err["message"] =~ "content.rev"
      refute err["message"] =~ "your copy anchored on"
    end

    test "an unreadable content[\"rev\"] refuses on pull too, rather than serving a substitute",
         %{conn: conn} do
      slug = "rev-anchor-unreadable-pull"
      publish!(slug) |> set_content_rev(%{"n" => 3})

      pulled = pull(conn, slug)
      assert %{"error" => err} = json_response(pulled, 422)
      assert err["code"] == "paper_rev_unreadable"
      assert err["message"] =~ slug
      assert err["message"] =~ "content.rev"
      assert get_resp_header(pulled, "x-paper-rev") == []
    end
  end

  describe "a genuine mismatch still 412s" do
    test "a stale baseRev on a normal paper refuses with BOTH revs named", %{conn: conn} do
      slug = "rev-anchor-mismatch"
      publish!(slug)

      pulled = pull(conn, slug)
      assert [anchor] = get_resp_header(pulled, "x-paper-rev")
      assert anchor != ""
      stale = to_string(String.to_integer(anchor) + 41)

      pushed =
        authed(build_conn())
        |> post("#{@ingest_path}/#{slug}/sync", %{
          "bpml" => response(pulled, 200),
          "baseRev" => stale
        })

      assert %{"error" => err} = json_response(pushed, 412)
      assert err["code"] == "precondition_failed"
      assert err["message"] == "paper is at rev #{anchor}, your copy anchored on #{stale}"
      # the server-side comparand is never blank
      refute err["message"] =~ "at rev ,"
    end

    test "a stale baseRev on a REVLESS paper still refuses — the fix did not open the door",
         %{conn: conn} do
      slug = "rev-anchor-revless-mismatch"
      publish!(slug) |> set_content_rev(:remove)

      pulled = pull(conn, slug)

      pushed =
        authed(build_conn())
        |> post("#{@ingest_path}/#{slug}/sync", %{
          "bpml" => response(pulled, 200),
          "baseRev" => "7"
        })

      assert %{"error" => err} = json_response(pushed, 412)
      assert err["message"] == "paper is at rev 0, your copy anchored on 7"
    end
  end

  describe "Content.Papers.op_rev/1 — the one owner" do
    test "absence is 0 (legitimate), a non-integer is a failed read" do
      assert Content.Papers.op_rev(%{content: %{"rev" => 5}}) == {:ok, 5}
      assert Content.Papers.op_rev(%{content: %{}}) == {:ok, 0}
      assert Content.Papers.op_rev(%{content: nil}) == {:ok, 0}

      assert Content.Papers.op_rev(%{content: %{"rev" => "5"}}) ==
               {:error, {:unreadable_rev, "content.rev"}}

      assert Content.Papers.op_rev(%{content: %{"rev" => %{}}}) ==
               {:error, {:unreadable_rev, "content.rev"}}
    end
  end
end
