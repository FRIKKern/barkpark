defmodule BarkparkWeb.BulldocsPapersTitleHonouredTest do
  @moduledoc """
  `POST /v1/plugins/bulldocs/papers` used to accept a top-level `"title"` in
  the JSON body and drop it on the floor: `ingest_blocks/4`'s closed attrs
  whitelist carried no `"title"`, so `BlockOps.paper_title/2`'s
  `content["title"]` branch was unreachable from HTTP and the stored row title
  silently became the first heading block's text (or the slug). The receipt was
  the ordinary `{"ok":true,"rev":…,"slug":…}` — honoured and discarded were
  BYTE-IDENTICAL on the wire.

  The sibling dry-run `POST /papers/validate` DOES read the key (it walls a ref
  document built with `title: merged["title"]`), so a producer could validate a
  body, see it pass under its title, POST the identical body, get 200 ok — and
  a different title was stored. The JS SDK's `Paper#toJSON` documents and emits
  exactly that key ("the ingest accepts `{ slug, title?, style?, blocks }`"),
  and the BPML grammar spells it as the `<paper title="…">` attribute, so real
  producers send it.

  These tests assert on the STORED title and on the RESPONSE the caller sees,
  so removing the whitelist entry or the receipt echo reds them.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp post_paper(conn, payload) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(@path, payload)
  end

  # The producer shape the row names: the bp CLI file/stdin payload path (and
  # the JS SDK's `publish`) POST a block list plus top-level attrs.
  defp blocks_body(slug, extra) do
    LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "blocks" => [
        %{"type" => "heading", "level" => 1, "text" => "A Heading That Is Not The Title"},
        %{
          "type" => "paragraph",
          "content" => [
            %{
              "type" => "text",
              "text" =>
                "Body copy long enough that the hollow-paper gate sees a real document " <>
                  "and not a skeleton with a lone heading block on top of it."
            }
          ]
        }
      ]
    })
    |> Map.merge(extra)
  end

  describe "a top-level title on the publish route" do
    test "is HONOURED — it becomes the stored row title, beating the first heading",
         %{conn: conn} do
      slug = uniq("title-honoured")
      title = "The Title The Caller Sent"

      conn = post_paper(conn, blocks_body(slug, %{"title" => title}))

      assert json_response(conn, 200)["ok"] == true

      paper = Content.get_paper(slug)
      assert paper
      assert paper.title == title
      assert get_in(paper.content, ["title"]) == title
    end

    test "is ECHOED in the receipt, so honoured and discarded are not byte-identical",
         %{conn: conn} do
      slug = uniq("title-echo")
      title = "An Echoed Title"

      conn = post_paper(conn, blocks_body(slug, %{"title" => title}))

      resp = json_response(conn, 200)
      assert resp["title"] == title
      assert resp["title"] == Content.get_paper(slug).title
    end

    test "agrees with the /papers/validate dry-run about the same body", %{conn: conn} do
      slug = uniq("title-validate-parity")
      title = "A Title Both Doors Agree On"
      payload = blocks_body(slug, %{"title" => title})

      dry =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path <> "/validate", payload)
        |> json_response(200)

      assert dry["valid"] == true, "dry-run refused the body: #{inspect(dry["violations"])}"

      real = post_paper(Phoenix.ConnTest.build_conn(), payload) |> json_response(200)

      # The dry-run walled the document under `title`; the real run must store
      # that same title, or the two doors disagree about one field of one body.
      assert real["title"] == title
      assert Content.get_paper(slug).title == title
    end
  end

  describe "control — the change is narrow" do
    test "with NO title the first heading still wins (legacy derivation untouched)",
         %{conn: conn} do
      slug = uniq("title-absent-control")

      conn = post_paper(conn, blocks_body(slug, %{}))

      resp = json_response(conn, 200)
      assert resp["title"] == "A Heading That Is Not The Title"
      assert Content.get_paper(slug).title == "A Heading That Is Not The Title"
    end

    test "a blank title falls back to the heading rather than storing an empty row title",
         %{conn: conn} do
      slug = uniq("title-blank-control")

      conn = post_paper(conn, blocks_body(slug, %{"title" => ""}))

      assert json_response(conn, 200)["title"] == "A Heading That Is Not The Title"
      assert Content.get_paper(slug).title == "A Heading That Is Not The Title"
    end
  end

  describe "the heading fallback reads the content-array heading form" do
    # bp-paper-ingest-title-trap: `paper_title/2`'s heading fallback matched
    # ONLY `b["text"]`. A heading authored in the normal PortableDoc inline
    # form (`content: [%{"type" => "text", "value" => …}]`) with no explicit
    # title therefore missed the fallback entirely and the row title fell
    # silently to the slug.
    defp array_heading_body(slug) do
      LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "blocks" => [
          %{
            "type" => "heading",
            "level" => 1,
            "content" => [%{"type" => "text", "value" => "An Array-Authored Heading"}]
          },
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  "Body copy long enough that the hollow-paper gate sees a real document " <>
                    "and not a skeleton with a lone heading block on top of it."
              }
            ]
          }
        ]
      })
    end

    test "a content-array heading with NO title becomes the stored row title, not the slug",
         %{conn: conn} do
      slug = uniq("array-heading-title")

      conn = post_paper(conn, array_heading_body(slug))

      assert json_response(conn, 200)["ok"] == true

      paper = Content.get_paper(slug)
      assert paper
      refute paper.title == slug, "row title fell back to the slug"
      assert paper.title == "An Array-Authored Heading"
    end

    test "the /papers/validate precheck twin derives the SAME array-heading title",
         %{conn: conn} do
      slug = uniq("array-heading-validate")
      payload = array_heading_body(slug)

      dry =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path <> "/validate", payload)
        |> json_response(200)

      assert dry["valid"] == true, "dry-run refused the body: #{inspect(dry["violations"])}"

      real = post_paper(Phoenix.ConnTest.build_conn(), payload) |> json_response(200)
      assert real["title"] == "An Array-Authored Heading"
    end
  end

  describe "the shared heading derivation both doors now read" do
    alias Barkpark.Content.Papers.BlockOps

    test "heading_title/1 reads BOTH authored heading forms, and nothing else" do
      assert BlockOps.heading_title([%{"type" => "heading", "text" => "Flat"}]) == "Flat"

      assert BlockOps.heading_title([
               %{"type" => "heading", "content" => [%{"type" => "text", "value" => "Array"}]}
             ]) == "Array"

      # Marks flatten; the first heading wins; a non-heading never answers.
      assert BlockOps.heading_title([
               %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Body"}]},
               %{
                 "type" => "heading",
                 "content" => [
                   %{"type" => "text", "value" => "Bold "},
                   %{"type" => "strong", "content" => [%{"type" => "text", "value" => "Head"}]}
                 ]
               },
               %{"type" => "heading", "text" => "Second"}
             ]) == "Bold Head"

      # No printable heading text anywhere => nil, so the caller falls through
      # to its own fallback (parsed title, then slug) rather than storing "".
      assert BlockOps.heading_title([%{"type" => "heading", "text" => ""}]) == nil
      assert BlockOps.heading_title([%{"type" => "heading", "content" => []}]) == nil
      assert BlockOps.heading_title([%{"type" => "paragraph", "text" => "Not a heading"}]) == nil
      assert BlockOps.heading_title(nil) == nil
    end

    # WHY THIS PIN EXISTS (bp-paper-ingest-title-trap): the create-on-push
    # precheck twin (`create_title/3` in BulldocsIngestController) had the same
    # `b["text"]`-only match. It now DELEGATES to `heading_title/1`, so the two
    # derivations cannot drift again — but the twin's old blindness was never
    # reachable in the first place, because `POST /papers/:slug/sync` is
    # BPML-only and the BPML parser emits headings in the FLAT `"text"` form.
    # That is the premise that makes the twin untestable end-to-end, so it is
    # pinned here: if the parser ever starts emitting array-form headings, this
    # reds and the next reader learns the twin's derivation now matters live.
    test "BPML parses an h1 into the FLAT text form — the premise the twin rests on" do
      {:ok, parsed} =
        Barkpark.PortableDoc.Bpml.parse_paper(
          ~s(<paper slug="pin"><h1>Hello World</h1><p>Body</p></paper>)
        )

      assert [%{"type" => "heading", "text" => "Hello World"} | _] = parsed["blocks"]
    end
  end
end
