defmodule BarkparkWeb.ExportPerspectiveTest do
  @moduledoc """
  task-c14e213b4a7b0ef1: `GET /v1/data/export/:dataset` honours `?perspective`.

  On main the route read only `type`. `bp export --perspective published`, the
  raw route, and `exportDataset({perspective: "published"})` all streamed every
  draft (215 of 215 rows in the Lane D walk, 190 of them drafts).

  The fixture is one dataset holding three logical documents:

    * `pub-only`: published, with no draft;
    * `both`: published, plus a newer `drafts.both` twin;
    * `draft-only`: exists only as `drafts.draft-only`.

  | lens      | rows                                               |
  |-----------|----------------------------------------------------|
  | raw       | all four rows                                      |
  | published | `pub-only`, `both`                                 |
  | drafts    | `pub-only`, `drafts.both`, `drafts.draft-only`     |

  Tiers: a `read` token, a `write` token, an `admin` token, and a
  `public-read` token (refused the route by the `:require_token` clamp, which
  is pinned here).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}

  @dataset "expperspective"

  setup do
    Auth.create_token("xp-read", "read", @dataset, ["read"])
    Auth.create_token("xp-write", "write", @dataset, ["read", "write"])
    Auth.create_token("xp-admin", "admin", @dataset, ["read", "write", "admin"])
    Auth.create_token("xp-public", "public", @dataset, ["public-read"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    {:ok, _} = Content.create_document("post", %{"_id" => "pub-only", "title" => "P"}, @dataset)
    {:ok, _} = Content.publish_document("pub-only", "post", @dataset)
    {:ok, _} = Content.create_document("post", %{"_id" => "both", "title" => "B1"}, @dataset)
    {:ok, _} = Content.publish_document("both", "post", @dataset)

    {:ok, _} =
      Content.create_document("post", %{"_id" => "drafts.both", "title" => "B2"}, @dataset)

    {:ok, _} = Content.create_document("post", %{"_id" => "draft-only", "title" => "D"}, @dataset)
    :ok
  end

  defp export(token, query) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> get("/v1/data/export/#{@dataset}#{query}")
  end

  defp ids(conn) do
    assert conn.status == 200, conn.resp_body

    conn.resp_body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!(&1)["_id"])
    |> Enum.sort()
  end

  @raw ["both", "drafts.both", "drafts.draft-only", "pub-only"]
  @published ["both", "pub-only"]
  @drafts ["drafts.both", "drafts.draft-only", "pub-only"]

  for token <- ["xp-read", "xp-write", "xp-admin"] do
    describe "#{token} token" do
      test "?perspective=published streams no draft row" do
        assert ids(export(unquote(token), "?perspective=published")) == @published
      end

      test "?perspective=drafts is draft-over-published, one row per document" do
        assert ids(export(unquote(token), "?perspective=drafts")) == @drafts
      end

      test "?perspective=raw streams every row" do
        assert ids(export(unquote(token), "?perspective=raw")) == @raw
      end

      test "an unknown perspective is a 400 before the stream opens" do
        conn = export(unquote(token), "?perspective=drafst")
        assert conn.status == 400
        body = Jason.decode!(conn.resp_body)
        assert body["error"]["code"] == "malformed"
        assert body["error"]["details"]["supported"] == ["published", "drafts", "raw"]
      end

      test "perspective composes with ?type" do
        assert ids(export(unquote(token), "?perspective=published&type=post")) == @published
      end
    end
  end

  describe "the default when ?perspective is omitted" do
    test "a read-only token gets published, the query route's default for that tier" do
      assert ids(export("xp-read", "")) == @published
    end

    test "a write token keeps raw, the backup every export took before" do
      assert ids(export("xp-write", "")) == @raw
    end

    test "an admin token keeps raw" do
      assert ids(export("xp-admin", "")) == @raw
    end
  end

  test "a public-read token is refused the route outright (pinned: the clamp, not the lens)" do
    conn = export("xp-public", "?perspective=raw")
    assert conn.status == 403
  end
end
