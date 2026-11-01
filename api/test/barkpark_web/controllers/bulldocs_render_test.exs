defmodule BarkparkWeb.BulldocsRenderTest do
  @moduledoc """
  R4.4a (task-c6ebe6038ad7afb4): `POST /v1/plugins/bulldocs/render` hands back
  the paper reader's HTML for a doc in the body and stores nothing.

    * a golden doc renders byte-equal to the pd-parity goldens' `expectedHtml`
      (what `/papers/:slug` renders per block), and no table gains or loses a
      row;
    * a broken doc, an oversized body and an unauthenticated call each get a
      4xx with a reason — never HTML, never a 500.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, TenancyFixtures}
  alias Barkpark.PortableDoc.Validate

  @path "/v1/plugins/bulldocs/render"
  @dataset "production"
  @goldens "test/support/fixtures/pd-parity"

  defp goldens do
    @goldens
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".golden.json"))
    |> Enum.sort()
    |> Enum.map(&(@goldens |> Path.join(&1) |> File.read!() |> Jason.decode!()))
  end

  defp golden_blocks do
    goldens()
    |> Enum.with_index()
    |> Enum.map(fn {g, i} -> Map.put(g["input"], "id", "golden-#{i}") end)
  end

  defp token! do
    ws = TenancyFixtures.create_workspace!()
    TenancyFixtures.create_project!(ws, "default")
    raw = "render-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "render admin", @dataset, ["admin"], ws.id)
    raw
  end

  defp read_token! do
    raw = "render-read-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "render reader", @dataset, ["read"])
    raw
  end

  defp post_render(body, token) do
    conn = put_req_header(scoped_conn(), "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, @path, body)
  end

  defp post_each(bodies) do
    bodies
    |> Enum.chunk_every(50)
    |> Enum.flat_map(fn chunk ->
      token = token!()
      Enum.map(chunk, &post_render(Jason.encode!(&1), token))
    end)
  end

  defp error(resp), do: Jason.decode!(resp.resp_body)["error"]

  defp row_counts do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name"
      )

    Map.new(tables, fn [t] ->
      %{rows: [[n]]} = Repo.query!(~s[SELECT count(*) FROM "#{t}"])
      {t, n}
    end)
  end

  setup do
    TenancyFixtures.ensure_default_scope!()
    %{token: token!()}
  end

  describe "a golden doc" do
    test "renders byte-equal to the reader's per-block golden HTML, joined", %{token: token} do
      goldens = goldens()
      assert length(goldens) >= 80

      resp = post_render(Jason.encode!(%{"blocks" => golden_blocks()}), token)

      assert resp.status == 200, resp.resp_body

      assert Jason.decode!(resp.resp_body)["html"] ==
               Enum.map_join(goldens, "", & &1["expectedHtml"])
    end

    test "each golden alone renders its own expectedHtml" do
      resps = post_each(Enum.map(golden_blocks(), &%{"blocks" => [&1]}))

      for {block, golden, resp} <- Enum.zip([golden_blocks(), goldens(), resps]) do
        assert resp.status == 200, "#{block["type"]}: #{resp.resp_body}"
        assert Jason.decode!(resp.resp_body)["html"] == golden["expectedHtml"], block["type"]
      end
    end

    test "writes nothing: every table keeps its row count", %{token: token} do
      body = Jason.encode!(%{"blocks" => golden_blocks()})
      before = row_counts()
      assert map_size(before) > 20

      assert post_render(body, token).status == 200
      assert post_render(Jason.encode!(%{"blocks" => [%{"type" => "nope"}]}), token).status == 422

      assert row_counts() == before
    end
  end

  describe "a broken doc" do
    test "gets 422 with every violation, and no HTML", %{token: token} do
      resp =
        post_render(
          Jason.encode!(%{
            "blocks" => [
              %{"type" => "nope"},
              %{"type" => "heading", "level" => "one", "text" => "x"}
            ]
          }),
          token
        )

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      refute Map.has_key?(body, "html")
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["message"] =~ "violation"

      assert %{"code" => "unknown_block_type", "path" => "/blocks/0/type"} in body["error"][
               "violations"
             ]

      assert Enum.any?(body["error"]["violations"], &(&1["path"] =~ "/blocks/1"))
    end

    test "with no blocks array gets 422 not_a_doc", %{token: token} do
      for body <- [
            %{},
            %{"blocks" => "x"},
            %{"blocks" => %{}},
            %{"blocks" => nil},
            [%{"type" => "divider"}]
          ] do
        resp = post_render(Jason.encode!(body), token)
        assert resp.status == 422
        assert error(resp)["violations"] == [%{"code" => "not_a_doc", "path" => "/blocks"}]
      end
    end

    test "a block at the depth cap gets 422 too_deep; one level less renders", %{token: token} do
      leaf = %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "deep"}]}

      nest = fn levels ->
        Enum.reduce(1..levels, leaf, fn i, inner ->
          %{"id" => "s#{i}", "type" => "section", "blocks" => [inner]}
        end)
      end

      at_cap = post_render(Jason.encode!(%{"blocks" => [nest.(Validate.max_depth())]}), token)
      assert at_cap.status == 422

      assert error(at_cap)["violations"] == [
               %{
                 "code" => "too_deep",
                 "path" => "/blocks/0" <> String.duplicate("/blocks/0", Validate.max_depth())
               }
             ]

      under = post_render(Jason.encode!(%{"blocks" => [nest.(Validate.max_depth() - 1)]}), token)
      assert under.status == 200, under.resp_body
      assert Jason.decode!(under.resp_body)["html"] =~ "deep"
    end

    test "that validates but the renderer cannot draw gets 422 unrenderable", %{token: token} do
      ok = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "x"}]
      }

      bad = %{
        "id" => "f",
        "type" => "field-select",
        "label" => "Status",
        "options" => [1],
        "value" => "live"
      }

      assert Validate.validate([ok, bad]) == :ok

      resp = post_render(Jason.encode!(%{"blocks" => [ok, bad]}), token)

      assert resp.status == 422
      assert error(resp)["violations"] == [%{"code" => "unrenderable", "path" => "/blocks/1"}]
    end

    test "a field of every JSON type in every golden never gets a 500" do
      values = [nil, 1, "x", [], %{}, [1], [%{}]]

      variants =
        for block <- golden_blocks(),
            {key, _} <- block,
            key not in ["id", "type"],
            v <- values,
            do: Map.put(block, key, v)

      statuses =
        variants
        |> Enum.map(&%{"blocks" => [&1]})
        |> post_each()
        |> Enum.frequencies_by(& &1.status)

      assert Map.keys(statuses) -- [200, 422] == [], inspect(statuses)
      assert statuses[200] > 100 and statuses[422] > 100, inspect(statuses)
    end

    test "a body that is not JSON gets 400 malformed", %{token: token} do
      resp = post_render("{\"blocks\": [", token)
      assert resp.status == 400
      assert error(resp)["code"] == "malformed"
    end
  end

  describe "the door" do
    test "an oversized body gets 413 payload_too_large", %{token: token} do
      resp = post_render(String.duplicate(" ", 100_000_001), token)

      assert resp.status == 413
      assert error(resp)["code"] == "payload_too_large"
    end

    test "no token, a bad token and a read-only token each get 401 with a reason" do
      for token <- [nil, "not-a-token", read_token!()] do
        resp = post_render(Jason.encode!(%{"blocks" => golden_blocks()}), token)
        assert resp.status == 401
        assert error(resp)["code"] == "unauthorized"
        assert error(resp)["message"] =~ "token"
        refute Map.has_key?(Jason.decode!(resp.resp_body), "html")
      end
    end
  end
end
