defmodule BarkparkWeb.TokenDatasetBindingTest do
  @moduledoc """
  task-4418b517649a58ce — a token minted with an explicit `dataset` is held to
  it on the scoped data routes.

  Live repro (guerrilla, 2026-10-09): an app token minted with
  `"dataset": "e2e-local"` read (200) and mutated (200, forked a draft) a
  document in `e2e-sanity-builder` of the same workspace and project. The
  `dataset` column defaults to `"production"` on every row and nothing ever
  read it on a request, so the binding was stored and never enforced.

  Ruling B (run8 lead): `dataset_bound` is set ONLY when the mint request
  names a dataset. A bound token is refused (403 `dataset_not_bound`) on any
  other dataset; on its own it is admitted. An unbound token (NULL — every row
  minted before the column) keeps today's cross-dataset access.

  Every refusal test has a positive control on the token's OWN dataset, so a
  403 cannot come from a broken fixture (no seat, no schema, wrong slug).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  @own "e2e-local"
  @other "e2e-sanity-builder"

  setup :reset_rate_limiter!

  setup do
    for ds <- [@own, @other] do
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "private", "fields" => []},
        ds
      )
    end

    ws = create_workspace!()
    proj = create_project!(ws)

    for ds <- [@own, @other] do
      create_document_in!(ws, proj, "post", %{"doc_id" => "post-05", "title" => "in #{ds}"}, ds)
    end

    admin = "dsb-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "dsb-admin", "production", ["read", "write", "admin"])

    %{ws: ws, proj: proj, admin: admin}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp mint_app(admin, ws, extra) do
    body =
      Map.merge(
        %{
          email: "dsb-#{System.unique_integer([:positive])}@example.com",
          workspace: ws.slug,
          permissions: ["read", "write"]
        },
        extra
      )

    conn = as(admin) |> post("/v1/auth/app-tokens", Jason.encode!(body))
    assert conn.status == 201, conn.resp_body
    Jason.decode!(conn.resp_body)["token"]
  end

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data"

  defp get_doc(raw, ws, proj, ds),
    do: as(raw) |> get("#{base(ws, proj)}/doc/#{ds}/post/post-05?perspective=drafts")

  defp query(raw, ws, proj, ds),
    do: as(raw) |> get("#{base(ws, proj)}/query/#{ds}/post")

  defp patch(raw, ws, proj, ds) do
    body = %{
      "mutations" => [
        %{"patch" => %{"id" => "post-05", "type" => "post", "set" => %{"title" => "probe"}}}
      ]
    }

    as(raw) |> post("#{base(ws, proj)}/mutate/#{ds}", Jason.encode!(body))
  end

  defp listen(raw, ws, proj, ds),
    do: as(raw) |> get("#{base(ws, proj)}/listen/#{ds}")

  defp export(raw, ws, proj, ds),
    do: as(raw) |> get("#{base(ws, proj)}/export/#{ds}")

  defp assert_dataset_refusal(conn) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    assert Jason.decode!(conn.resp_body)["error"]["reason"] == "dataset_not_bound", conn.resp_body
  end

  defp titles_in(ds) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(d in Content.Document,
        where: d.dataset == ^ds and like(d.doc_id, "%post-05"),
        select: d.title
      )
    )
  end

  defp token_row(raw), do: Repo.get_by!(ApiToken, token_hash: ApiToken.hash_token(raw))

  # ── mint ───────────────────────────────────────────────────────────────────

  describe "mint" do
    test "an app token minted WITH dataset is bound; WITHOUT it is not", %{admin: admin, ws: ws} do
      bound = mint_app(admin, ws, %{dataset: @own})
      unbound = mint_app(admin, ws, %{})

      assert %ApiToken{dataset: @own, dataset_bound: true} = token_row(bound)
      assert %ApiToken{dataset: "production", dataset_bound: nil} = token_row(unbound)
    end

    test "GET /v1/auth/token reports dataset_bound", %{admin: admin, ws: ws} do
      bound = mint_app(admin, ws, %{dataset: @own})
      unbound = mint_app(admin, ws, %{})

      b = as(bound) |> get("/v1/auth/token") |> json_response(200)
      u = as(unbound) |> get("/v1/auth/token") |> json_response(200)

      assert {b["dataset"], b["dataset_bound"]} == {@own, true}
      assert {u["dataset"], u["dataset_bound"]} == {"production", false}
    end
  end

  # ── the live repro: a bound APP token ──────────────────────────────────────

  describe "bound app token" do
    setup %{admin: admin, ws: ws} do
      %{tok: mint_app(admin, ws, %{dataset: @own})}
    end

    test "reads its own dataset (positive control)", %{tok: tok, ws: ws, proj: proj} do
      assert get_doc(tok, ws, proj, @own).status == 200
      assert query(tok, ws, proj, @own).status == 200
    end

    test "is refused reading another dataset (doc get + query)", %{tok: tok, ws: ws, proj: proj} do
      assert_dataset_refusal(get_doc(tok, ws, proj, @other))
      assert_dataset_refusal(query(tok, ws, proj, @other))
    end

    test "writes its own dataset (positive control)", %{tok: tok, ws: ws, proj: proj} do
      conn = patch(tok, ws, proj, @own)
      assert conn.status == 200, conn.resp_body
      assert "probe" in titles_in(@own)
    end

    test "is refused writing another dataset, and nothing is written",
         %{tok: tok, ws: ws, proj: proj} do
      before = titles_in(@other)
      assert_dataset_refusal(patch(tok, ws, proj, @other))
      assert titles_in(@other) == before
      refute "probe" in titles_in(@other)
    end

    test "is refused on listen and export of another dataset", %{tok: tok, ws: ws, proj: proj} do
      assert_dataset_refusal(listen(tok, ws, proj, @other))
      assert_dataset_refusal(export(tok, ws, proj, @other))
    end

    test "exports its own dataset (positive control for the require_token arm)",
         %{tok: tok, ws: ws, proj: proj} do
      assert export(tok, ws, proj, @own).status == 200
    end
  end

  # ── a plain bound api token, through the same doors ────────────────────────

  describe "bound plain api token" do
    setup %{ws: ws} do
      raw = "dsb-api-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "dsb-api", @own, ["read", "write"], ws.id, dataset_bound: true)

      %{tok: raw}
    end

    test "own dataset admitted, another refused (read + write)", %{tok: tok, ws: ws, proj: proj} do
      assert get_doc(tok, ws, proj, @own).status == 200
      assert_dataset_refusal(get_doc(tok, ws, proj, @other))
      assert_dataset_refusal(patch(tok, ws, proj, @other))
    end
  end

  # ── the flat routes: RequireToken / OptionalToken are the door ─────────────

  describe "bound token on the flat /v1/data routes" do
    setup do
      raw = "dsb-flat-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "dsb-flat", @own, ["read", "write"], nil, dataset_bound: true)

      %{tok: raw}
    end

    test "own dataset admitted, another refused (query, export, mutate)", %{tok: tok} do
      assert (as(tok) |> get("/v1/data/query/#{@own}/post")).status == 200
      assert_dataset_refusal(as(tok) |> get("/v1/data/query/#{@other}/post"))
      assert_dataset_refusal(as(tok) |> get("/v1/data/export/#{@other}"))

      body =
        Jason.encode!(%{"mutations" => [%{"create" => %{"_type" => "post", "title" => "x"}}]})

      assert_dataset_refusal(as(tok) |> post("/v1/data/mutate/#{@other}", body))
    end
  end

  # ── unbound tokens keep today's behaviour ──────────────────────────────────

  describe "unbound token (legacy NULL)" do
    test "an app token minted without dataset still reads and writes any dataset",
         %{admin: admin, ws: ws, proj: proj} do
      tok = mint_app(admin, ws, %{})

      assert get_doc(tok, ws, proj, @other).status == 200
      assert get_doc(tok, ws, proj, @own).status == 200
      assert patch(tok, ws, proj, @other).status == 200
    end

    test "a plain token whose dataset is only the default is not held to it",
         %{ws: ws, proj: proj} do
      raw = "dsb-legacy-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "dsb-legacy", @own, ["read", "write"], ws.id)
      assert %ApiToken{dataset_bound: nil} = token_row(raw)

      assert get_doc(raw, ws, proj, @other).status == 200
      assert patch(raw, ws, proj, @other).status == 200
    end
  end
end
