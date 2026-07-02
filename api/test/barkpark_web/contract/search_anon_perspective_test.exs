defmodule BarkparkWeb.Contract.SearchAnonPerspectiveTest do
  @moduledoc """
  DB-backed anonymous-context locks for the search draft-disclosure pin
  (the verification PR #670 was held for): an anonymous caller of EITHER
  search surface must never see draft rows — with no params, and even when
  explicitly asking for `?perspective=drafts` or `raw`. Authed callers keep
  drafts (preview must not break).

  The seed makes the draft content DISTINGUISHABLE: `leaky` exists ONLY as a
  draft; `pubdoc` is published and its draft was then edited, so its draft
  title differs from its published title.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  @ds "anon-persp-test"

  setup do
    Auth.create_token("barkpark-dev-token", "dev", @ds, ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    # Published doc whose DRAFT then diverged.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.pubdoc", "title" => "Zebrafinch Public Title"},
        @ds
      )

    {:ok, _} = Content.publish_document("pubdoc", "post", @ds)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.pubdoc", "title" => "Zebrafinch SECRET Draft Edit"},
        @ds
      )

    # Draft-ONLY doc — must be invisible to anonymous search entirely.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.leaky", "title" => "Zebrafinch Unpublished Leak"},
        @ds
      )

    :ok
  end

  defp titles(body, key), do: body |> Map.fetch!(key) |> Enum.map(& &1["title"])

  defp anon_search(conn, params) do
    resp = get(conn, "/v1/data/search/#{@ds}", params)
    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  defp federated(conn, params) do
    resp = get(conn, "/v1/search/#{@ds}", params)
    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  defp federated_titles(body) do
    body
    |> get_in(["results", "documents", "hits"])
    |> List.wrap()
    |> Enum.map(& &1["title"])
  end

  describe "anonymous callers are pinned to :published" do
    test "/v1/data/search with no params excludes drafts", %{conn: conn} do
      body = anon_search(conn, %{"q" => "zebrafinch"})
      assert titles(body, "documents") == ["Zebrafinch Public Title"]
    end

    test "/v1/data/search ignores an explicit ?perspective=drafts", %{conn: conn} do
      body = anon_search(conn, %{"q" => "zebrafinch", "perspective" => "drafts"})
      assert titles(body, "documents") == ["Zebrafinch Public Title"]
    end

    test "/v1/data/search ignores ?perspective=raw", %{conn: conn} do
      body = anon_search(conn, %{"q" => "zebrafinch", "perspective" => "raw"})
      assert titles(body, "documents") == ["Zebrafinch Public Title"]
    end

    test "federated search with no params excludes drafts", %{conn: conn} do
      body = federated(conn, %{"q" => "zebrafinch"})
      assert federated_titles(body) == ["Zebrafinch Public Title"]
    end

    test "federated search ignores an explicit ?perspective=drafts", %{conn: conn} do
      body = federated(conn, %{"q" => "zebrafinch", "perspective" => "drafts"})
      assert federated_titles(body) == ["Zebrafinch Public Title"]
    end
  end

  describe "authed callers keep drafts (preview unbroken)" do
    test "authed /v1/data/search?perspective=drafts returns the draft rows", %{conn: conn} do
      body =
        conn
        |> put_req_header("authorization", "Bearer barkpark-dev-token")
        |> anon_search(%{"q" => "zebrafinch", "perspective" => "drafts"})

      got = titles(body, "documents") |> Enum.sort()
      assert "Zebrafinch SECRET Draft Edit" in got
      assert "Zebrafinch Unpublished Leak" in got
    end

    test "authed federated ?perspective=drafts returns the draft rows", %{conn: conn} do
      body =
        conn
        |> put_req_header("authorization", "Bearer barkpark-dev-token")
        |> federated(%{"q" => "zebrafinch", "perspective" => "drafts"})

      got = federated_titles(body) |> Enum.sort()
      assert "Zebrafinch SECRET Draft Edit" in got
      assert "Zebrafinch Unpublished Leak" in got
    end
  end
end
