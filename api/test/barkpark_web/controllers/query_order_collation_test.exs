defmodule BarkparkWeb.QueryOrderCollationTest do
  @moduledoc """
  `?collation=` on `GET /v1/data/query/:dataset/:type` (task-4973be61eff3bbe5).

  Without it, `?order=title:asc` follows the database collation. On the
  Gyldendal instance (gyl.barkpark.cloud) that files Å under A and Ø under O and skips leading punctuation, so a Norwegian
  catalogue paged by the server interleaves Å-titles with A-titles. With
  `collation=nb` the text keys sort by ICU Norwegian Bokmål: Æ, Ø and Å after
  Z, case-insensitive at the primary level, punctuation and digits first.

  The titles below are invented. The expected order is ICU `nb`'s, which is
  also what JavaScript's `Intl.Collator("nb")` returns for the same strings.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content

  @ds "query_order_collation_test"

  # Inserted in an order that matches neither the expected answer nor its
  # reverse, so a test cannot pass on insertion or `updated_at` order.
  @titles [
    "Ørnen",
    "abc",
    "Zebra",
    "Åpen dialog",
    "2 år",
    "Oslo",
    "«Sitat»",
    "Ærlig talt",
    "ørken",
    "Apen",
    "10 fortellinger"
  ]

  @nb_order [
    "«Sitat»",
    "10 fortellinger",
    "2 år",
    "abc",
    "Apen",
    "Oslo",
    "Zebra",
    "Ærlig talt",
    "ørken",
    "Ørnen",
    "Åpen dialog"
  ]

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "book", "title" => "Book", "visibility" => "public", "fields" => []},
        @ds
      )

    for {title, i} <- Enum.with_index(@titles) do
      {:ok, _} =
        Content.create_document(
          "book",
          %{"_id" => "b#{i}", "title" => title, "meta" => %{"sortName" => title}},
          @ds
        )

      {:ok, _} = Content.publish_document("b#{i}", "book", @ds)
    end

    :ok
  end

  defp titles(conn, query) do
    %{"result" => body} =
      conn |> get("/v1/data/query/#{@ds}/book?#{query}") |> json_response(200)

    Enum.map(body["documents"], & &1["title"])
  end

  describe "collation=nb" do
    test "title:asc puts Æ, Ø and Å after Z, in that order", %{conn: conn} do
      assert titles(conn, "order=title:asc&collation=nb") == @nb_order
    end

    test "title:desc is the exact reverse", %{conn: conn} do
      assert titles(conn, "order=title:desc&collation=nb") == Enum.reverse(@nb_order)
    end

    test "a content field's text key is collated too", %{conn: conn} do
      assert titles(conn, "order=meta.sortName:asc&collation=nb") == @nb_order
    end

    test "pages split the collated order without skipping or repeating", %{conn: conn} do
      first = titles(conn, "order=title:asc&collation=nb&limit=4&offset=0")
      second = titles(conn, "order=title:asc&collation=nb&limit=4&offset=4")
      third = titles(conn, "order=title:asc&collation=nb&limit=4&offset=8")

      assert first ++ second ++ third == @nb_order
    end

    test "a multi-field sort collates its text terms only", %{conn: conn} do
      assert titles(conn, "order=title:asc,_updatedAt:desc&collation=nb") == @nb_order
    end

    test "the drafts perspective sorts a merged draft twin by its draft title", %{conn: conn} do
      Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
      # "Zebra" (b2) gets an unpublished draft retitled "Ålesund": the merged
      # row must sort by the draft's title, among the Å titles.
      {:ok, _} = Content.create_document("book", %{"_id" => "b2", "title" => "Ålesund"}, @ds)

      expected =
        (@nb_order -- ["Zebra"])
        |> List.insert_at(length(@nb_order) - 2, "Ålesund")

      assert conn
             |> put_req_header("authorization", "Bearer barkpark-dev-token")
             |> titles("perspective=drafts&order=title:asc&collation=nb") == expected
    end

    test "collation=nn (Nynorsk) gives the same Norwegian order", %{conn: conn} do
      assert titles(conn, "order=title:asc&collation=nn") == @nb_order
    end
  end

  describe "refusals and controls" do
    test "an unknown collation is a 422 naming the accepted values", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds}/book?order=title:asc&collation=sv")

      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"

      [message] = body["error"]["details"]["collation"]
      assert message =~ ~s("sv")
      assert message =~ "nb, nn"
    end

    test "a blank collation is the same request as none", %{conn: conn} do
      assert titles(conn, "order=title:asc&collation=") == titles(conn, "order=title:asc")
    end

    test "Content.Query refuses a collation it has no clause for" do
      assert_raise ArgumentError, ~r/unsupported order/, fn ->
        Content.Query.list_documents_page("book", @ds,
          order: {:field, "title", :asc},
          collation: "sv"
        )
      end
    end
  end
end
