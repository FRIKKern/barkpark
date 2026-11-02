defmodule BarkparkWeb.BulldocsRenderTest do
  @moduledoc """
  R4.4a (task-c6ebe6038ad7afb4): `POST /v1/plugins/bulldocs/render` hands back
  the paper reader's HTML for a doc in the body and stores nothing.

    * a golden doc renders byte-equal to the pd-parity goldens' `expectedHtml`
      (what `/papers/:slug` renders per block), and no table gains or loses a
      row;
    * a broken doc, an oversized body, oversized HTML and an unauthenticated
      call each get a 4xx with a reason — never HTML, never a 500;
    * no request issues a write statement.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.{Auth, Repo, TenancyFixtures}
  alias Barkpark.PortableDoc.Validate
  alias BarkparkWeb.{BulldocsIngestController, Endpoint}

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

  defp golden(name) do
    @goldens
    |> Path.join("#{name}.golden.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("input")
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

  defp put_at(m, [k], v) when is_map(m), do: Map.put(m, k, v)
  defp put_at(l, [i], v) when is_list(l), do: List.replace_at(l, i, v)
  defp put_at(m, [k | rest], v) when is_map(m), do: Map.update!(m, k, &put_at(&1, rest, v))
  defp put_at(l, [i | rest], v) when is_list(l), do: List.update_at(l, i, &put_at(&1, rest, v))

  defp capture_sql(fun) do
    me = self()
    id = "render-sql-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _ -> if self() == me, do: send(me, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect_sql([])
  end

  defp collect_sql(acc) do
    receive do
      {:sql, query} -> collect_sql([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp paragraphs_body(cap) do
    block = fn i ->
      %{
        "id" => "p" <> String.pad_leading("#{i}", 7, "0"),
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => String.duplicate("word ", 70)}]
      }
    end

    size = byte_size(Jason.encode!(block.(0)))
    count = div(cap - byte_size(~s({"blocks":[]})) + 1, size + 1)
    Jason.encode!(%{"blocks" => Enum.map(1..count, block)})
  end

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

    test "writes nothing: no INSERT, UPDATE or DELETE runs, and every table keeps its row count",
         %{token: token} do
      bodies = [
        {Jason.encode!(%{"blocks" => golden_blocks()}), 200},
        {Jason.encode!(%{"blocks" => [%{"type" => "nope"}]}), 422},
        {Jason.encode!(%{"blocks" => [put_at(golden("field-select"), ["options", 0], true)]}),
         422}
      ]

      before = row_counts()
      assert map_size(before) > 20

      for {body, status} <- bodies do
        sql = capture_sql(fn -> assert post_render(body, token).status == status end)
        assert Enum.any?(sql, &(&1 =~ ~r/^\s*SELECT/i)), "no SQL was captured"
        assert Enum.reject(sql, &(&1 =~ ~r/^\s*SELECT/i)) == []
      end

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

    test "each shape that validates but crashes the renderer gets 422 unrenderable, logged by type and path without content",
         %{token: token} do
      shapes = [
        {"field-select", ["options", 1], true, "BadMapError"},
        {"paragraph", ["content", 5, "children"], true, "Protocol.UndefinedError"},
        {"chat-question", ["questions", 0, "question"], [nil, "SENTINEL-q"], "ArgumentError"},
        {"composite", ["fields", 1, "name"], %{"type" => "SENTINEL-c"}, "Protocol.UndefinedError"}
      ]

      for {type, path, value, raised} <- shapes do
        block = put_at(golden(type), path, value)
        assert Validate.validate([block]) == :ok

        log =
          capture_log(fn ->
            resp = post_render(Jason.encode!(%{"blocks" => [golden("divider"), block]}), token)
            assert resp.status == 422, "#{type}: #{resp.resp_body}"

            assert error(resp)["violations"] == [
                     %{"code" => "unrenderable", "path" => "/blocks/1"}
                   ]
          end)

        assert log =~ "bulldocs render: /blocks/1 (#{type}) raised #{raised}"
        refute log =~ "SENTINEL"
      end
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
    test "a real doc of exactly 2 MiB renders; one byte more gets 413 payload_too_large naming the cap",
         %{token: token} do
      cap = Endpoint.render_body_length()
      assert cap == 2 * 1024 * 1024
      body = paragraphs_body(cap)
      assert byte_size(body) > cap - 500 and byte_size(body) <= cap

      at_cap = post_render(body <> String.duplicate(" ", cap - byte_size(body)), token)
      assert at_cap.status == 200, String.slice(at_cap.resp_body, 0, 300)
      assert Jason.decode!(at_cap.resp_body)["html"] =~ "word word"

      over = post_render(body <> String.duplicate(" ", cap - byte_size(body) + 1), token)
      assert over.status == 413
      assert error(over)["code"] == "payload_too_large"
      assert error(over)["message"] =~ "2.0 MiB"
    end

    test "a heatmap, a diff, or two heatmaps under the body cap whose HTML passes 16 MiB get 413 render_too_large",
         %{token: token} do
      heatmap = fn side ->
        %{"type" => "heatmap", "cells" => List.duplicate(List.duplicate(0.5, side), side)}
      end

      text = String.duplicate("+  line(code)\n", 130_000)

      half = post_render(Jason.encode!(%{"blocks" => [heatmap.(480)]}), token)
      assert half.status == 200

      assert byte_size(Jason.decode!(half.resp_body)["html"]) in div(
               BulldocsIngestController.max_render_html_bytes(),
               2
             )..BulldocsIngestController.max_render_html_bytes()

      for blocks <- [
            [golden("divider"), heatmap.(690)],
            [golden("divider"), Map.put(golden("diff"), "diff", text)],
            [heatmap.(480), heatmap.(480)]
          ] do
        body = Jason.encode!(%{"blocks" => blocks})
        assert byte_size(body) <= Endpoint.render_body_length()
        resp = post_render(body, token)

        assert resp.status == 413,
               "#{List.last(blocks)["type"]}: #{String.slice(resp.resp_body, 0, 200)}"

        assert error(resp)["code"] == "render_too_large"

        assert error(resp)["details"]["limit_bytes"] ==
                 BulldocsIngestController.max_render_html_bytes()

        refute resp.resp_body =~ "<"
      end
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
