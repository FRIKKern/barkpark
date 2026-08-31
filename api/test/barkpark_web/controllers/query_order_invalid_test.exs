defmodule BarkparkWeb.QueryOrderInvalidTest do
  @moduledoc """
  Regression guard for `wb-api-order-spec-fail-loud`.

  `QueryController.parse_order/1` used to end in `_ -> :updated_at_desc`: an
  unrecognised non-empty `?order=` spec silently fell back to the default
  order instead of refusing the typo — a 200 in a DIFFERENT order than the
  caller asked for, not the order it actually requested (the Gyldendal field
  report S2 silent-failures class). The identical catch-all lived one layer
  down in `Barkpark.Content.Query.apply_order/2`.

  This file proves both halves fail LOUD:

    - the HTTP door (`GET /v1/data/query/:dataset/:type?order=...`) now 422s
      a malformed spec through the existing Ecto.Changeset `validation_failed`
      envelope, naming the bad spec and the accepted grammar in `details`;
    - an ABSENT `?order=`, `_updatedAt:asc`, and the nested dot-path form
      (`price.amount:desc`, the exact case the old code comment named) are
      UNCHANGED — this fix must not over-tighten;
    - `Content.Query.apply_order/2`'s sibling catch-all (latent for any
      caller that reaches it directly, bypassing the HTTP normalisation)
      raises instead of silently defaulting.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "query_order_invalid_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @ds
      )

    for {id, title, price} <- [{"o1", "Alpha", "30"}, {"o2", "Beta", "10"}, {"o3", "Gamma", "20"}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => title, "price" => %{"amount" => price}},
          @ds
        )

      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    :ok
  end

  describe "GET /v1/data/query/:dataset/:type?order=<malformed> — fails loud" do
    test "order=title (no direction) is a 422 naming the bad spec, not a 200", %{conn: conn} do
      # RED before the fix: this returned 200, documents in :updated_at_desc
      # order — a successful response in a DIFFERENT order than asked, the
      # exact silent-failure shape this task closes.
      resp = get(conn, "/v1/data/query/#{@ds}/post?order=title")

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"

      [message] = body["error"]["details"]["order"]
      assert message =~ ~s("title")
      assert message =~ "asc|desc"
    end

    test "order=title:sideways (bad direction) is a 422 naming the bad spec", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds}/post?order=title:sideways")

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"

      [message] = body["error"]["details"]["order"]
      assert message =~ ~s("title:sideways")
      assert message =~ "asc|desc"
    end

    test "a malformed spec inside a multi-field sort is also refused", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds}/post?order=title:asc,price:upward")

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"

      [message] = body["error"]["details"]["order"]
      assert message =~ ~s("price:upward")
    end
  end

  describe "control: no over-tightening" do
    test "an ABSENT ?order= still defaults to updated_at:desc with a 200", %{conn: conn} do
      %{"result" => body} =
        conn |> get("/v1/data/query/#{@ds}/post") |> json_response(200)

      assert length(body["documents"]) == 3
    end

    test "_updatedAt:asc still works", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds}/post?order=_updatedAt:asc")
      assert resp.status == 200
    end

    test "the nested dot-path form price.amount:desc still sorts correctly", %{conn: conn} do
      %{"result" => body} =
        conn
        |> get("/v1/data/query/#{@ds}/post?order=price.amount:desc")
        |> json_response(200)

      assert Enum.map(body["documents"], &get_in(&1, ["price", "amount"])) ==
               ["30", "20", "10"]
    end
  end

  describe "Content.Query.apply_order/2 — the latent catch-all" do
    test "an unsupported order term raises instead of silently defaulting" do
      assert_raise ArgumentError, ~r/unsupported order/, fn ->
        Content.Query.list_documents_page("post", @ds, order: :sideways)
      end
    end
  end
end
