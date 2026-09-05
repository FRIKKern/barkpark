defmodule BarkparkWeb.TagsRouteTest do
  @moduledoc """
  `GET /v1/data/tags/:dataset` (registry browse) + `GET
  /v1/data/tags/:dataset/:tag` (tag detail) — the ae-w10 tag-browse reads.

  Proves the route contracts:

    * BROWSE shape — `{result: {tags: [{tag, counts, total}], count}}`, rows
      sorted total DESC, per-type counts from `TagDistribution.per_type/3`,
      published-only, default types paper,task (`?type=` overrides).
    * TENANT FAIL-CLOSED — workspace A's registry NEVER counts workspace B's
      docs sharing the dataset string. The MUTATION TRIPWIRE: replacing
      `scope_opts(conn)` with `[]` in `tag_browse` degrades `per_type` to the
      daily worker's GLOBAL call shape and the leak test REDS (total 1 → 4 —
      the cross-tenant existence-count leak class `data_counts_test.exs`
      guards; red run documented in the task ledger).
    * DETAIL ranking — strength DESC NULLS LAST over `tags_meta` (legacy
      flat-tag carrier present but LAST — dual-shape safety), matched
      strength/rationale + title COLUMN + main_tag_match projected,
      published-only (a draft twin never listed).
    * AUTH — anon 404 on both reads (existence-hiding, like backlinks);
      scoped mounts mirror the flat reads.
    * MANIFEST — `tag.browse` + `tag.docs` at auth_tier "read", NEVER "none"
      (the doc.query silent-404 bug class, D71).

  Docs are inserted directly, stamped with the seeded Default workspace +
  project so the flat (Default-scoped) and `/w/default/p/default` mounts see
  the same rows (the `related_route_test.exs` precedent).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content.Document
  alias Barkpark.{Repo, Tenancy}

  @dataset "tags_route_test"
  @token "tags-route-token"

  setup do
    Barkpark.Auth.create_token(@token, "dev", @dataset, ["read", "write", "admin"])

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    # Browse census: "alpha" on 2 papers + 1 task (total 3), "beta" on 1 paper
    # (total 1), plus an off-default "post" carrier of alpha that must NOT
    # count under the paper,task default.
    insert_doc!("tg-p1", "Paper One", "paper", weighted([{"alpha", 80}]), ws, proj)
    insert_doc!("tg-p2", "Paper Two", "paper", weighted([{"alpha", 30}, {"beta", 50}]), ws, proj)
    insert_doc!("tg-t1", "Task One", "task", weighted([{"alpha", 60}]), ws, proj)
    insert_doc!("tg-post", "Post One", "post", weighted([{"alpha", 90}]), ws, proj)

    # Detail ranking fixture on tag "focus": title order inverts strength
    # order; one legacy flat carrier; one draft twin that must never list.
    insert_doc!("tg-weak", "A Weak", "paper", weighted([{"focus", 10}]), ws, proj)
    insert_doc!("tg-legacy", "M Legacy", "paper", %{"tags" => ["focus"]}, ws, proj)

    insert_doc!(
      "tg-strong",
      "Z Strong",
      "paper",
      weighted([{"focus", 90}]) |> Map.put("main_tag", "focus"),
      ws,
      proj
    )

    insert_doc!(
      "drafts.tg-strong",
      "Z Strong Draft",
      "paper",
      weighted([{"focus", 95}]),
      ws,
      proj
    )

    :ok
  end

  defp weighted(pairs) do
    %{
      "tags" =>
        Enum.map(pairs, fn {tag, strength} ->
          %{"tag" => tag, "strength" => strength, "rationale" => "r-#{tag}"}
        end)
    }
  end

  defp insert_doc!(doc_id, title, type, content, ws, proj, dataset \\ @dataset) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: type,
      dataset: dataset,
      title: title,
      status: "published",
      content: content,
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: ws.id,
      project_id: proj.id
    })
  end

  defp authed(conn, token \\ @token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "GET /v1/data/tags/:dataset (registry browse)" do
    test "returns per-tag per-type counts sorted total DESC, published paper,task only", %{
      conn: conn
    } do
      body =
        conn
        |> authed()
        |> get("/v1/data/tags/#{@dataset}")
        |> json_response(200)

      %{"result" => %{"tags" => tags, "count" => count}} = body
      assert count == length(tags)
      assert body["syncTags"] == ["bp:ds:#{@dataset}:tags"]

      alpha = Enum.find(tags, &(&1["tag"] == "alpha"))
      # The type-"post" alpha carrier is OUTSIDE the paper,task default.
      assert alpha["counts"] == %{"paper" => 2, "task" => 1}
      assert alpha["total"] == 3

      beta = Enum.find(tags, &(&1["tag"] == "beta"))
      assert beta["counts"] == %{"paper" => 1}
      assert beta["total"] == 1

      # Sorted total DESC (tag asc tie-break) — the registry's contract.
      totals = Enum.map(tags, & &1["total"])
      assert totals == Enum.sort(totals, :desc)

      assert Enum.find_index(tags, &(&1["tag"] == "alpha")) <
               Enum.find_index(tags, &(&1["tag"] == "beta"))
    end

    test "?type= overrides the default census types", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/v1/data/tags/#{@dataset}?type=post")
        |> json_response(200)

      assert [%{"tag" => "alpha", "counts" => %{"post" => 1}, "total" => 1}] =
               body["result"]["tags"]
    end

    test "anon is existence-hidden (404, never a census)", %{conn: conn} do
      conn
      |> get("/v1/data/tags/#{@dataset}")
      |> json_response(404)
    end

    test "scoped mount /w/default/p/default mirrors the flat read", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/w/default/p/default/v1/data/tags/#{@dataset}")
        |> json_response(200)

      alpha = Enum.find(body["result"]["tags"], &(&1["tag"] == "alpha"))
      assert alpha["total"] == 3
    end
  end

  describe "browse tenancy (fail-closed — the scope_opts mutation tripwire)" do
    @leak_ds "tags_route_leak_ds"

    setup do
      # Two workspaces sharing one dataset string — the cross-tenant collision
      # axis. A holds 1 "leak"-tagged paper, B holds 3; an UNSCOPED per_type
      # call (the daily worker's opts: [] shape) would count all 4.
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "ws-a-tags", name: "WS A"})
      {:ok, proj_a} = Tenancy.create_project(ws_a, %{slug: "proj-a", name: "P A"})
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "ws-b-tags", name: "WS B"})
      {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "proj-b", name: "P B"})

      insert_doc!("lk-a1", "A One", "paper", weighted([{"leak", 50}]), ws_a, proj_a, @leak_ds)
      insert_doc!("lk-b1", "B One", "paper", weighted([{"leak", 50}]), ws_b, proj_b, @leak_ds)
      insert_doc!("lk-b2", "B Two", "paper", weighted([{"leak", 50}]), ws_b, proj_b, @leak_ds)
      insert_doc!("lk-b3", "B Three", "paper", weighted([{"leak", 50}]), ws_b, proj_b, @leak_ds)

      raw_a = "tags-leak-a-#{System.unique_integer([:positive])}"
      {:ok, _} = Barkpark.Auth.create_token(raw_a, "WS A token", @leak_ds, ["read"], ws_a.id)

      {:ok, raw_a: raw_a}
    end

    test "workspace A's registry NEVER counts workspace B's docs", %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-tags/p/proj-a/v1/data/tags/#{@leak_ds}")
        |> json_response(200)

      leak = Enum.find(body["result"]["tags"], &(&1["tag"] == "leak"))

      # The leak signature: an unscoped per_type call returns total 4 (A's 1 +
      # B's 3), exposing that B holds docs at all. Scoped, A sees only its own.
      assert leak["total"] == 1
      assert leak["counts"] == %{"paper" => 1}
    end
  end

  describe "GET /v1/data/tags/:dataset/:tag (tag detail)" do
    test "ranks by strength DESC NULLS LAST with the projection contract", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/v1/data/tags/#{@dataset}/focus")
        |> json_response(200)

      %{"result" => %{"tag" => "focus", "documents" => docs, "count" => count}} = body
      assert count == length(docs)
      assert body["syncTags"] == ["bp:ds:#{@dataset}:tags:focus"]

      # Strength order (90, 10, NULL-last legacy) — NOT title order — and the
      # drafts. twin (strength 95) never listed (published-only by design).
      assert Enum.map(docs, & &1["doc_id"]) == ["tg-strong", "tg-weak", "tg-legacy"]

      [strong, weak, legacy] = docs
      assert strong["strength"] == 90
      assert strong["rationale"] == "r-focus"
      assert strong["main_tag_match"] == true
      # The title COLUMN projection (content carries no usable title).
      assert strong["title"] == "Z Strong"
      assert strong["type"] == "paper"

      assert weak["main_tag_match"] == false

      # Dual-shape safety: the legacy flat carrier is listed, NULL-ranked.
      assert legacy["strength"] == nil
      assert legacy["rationale"] == nil
    end

    test "anon is existence-hidden (404)", %{conn: conn} do
      conn
      |> get("/v1/data/tags/#{@dataset}/focus")
      |> json_response(404)
    end

    test "scoped mount /w/default/p/default mirrors the flat read", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/w/default/p/default/v1/data/tags/#{@dataset}/focus")
        |> json_response(200)

      assert Enum.map(body["result"]["documents"], & &1["doc_id"]) ==
               ["tg-strong", "tg-weak", "tg-legacy"]
    end

    test "an unknown tag is an empty list, not an error", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/v1/data/tags/#{@dataset}/no-such-tag")
        |> json_response(200)

      assert body["result"]["documents"] == []
      assert body["result"]["count"] == 0
    end
  end

  describe "manifest" do
    test "tag.browse + tag.docs are read-tier GETs — NEVER none (D71)", %{conn: conn} do
      manifest =
        conn
        |> authed()
        |> get("/v1/capabilities")
        |> json_response(200)

      browse = Enum.find(manifest["commands"], &(&1["id"] == "tag.browse"))
      assert browse != nil, "tag.browse not found in manifest"
      assert browse["http"]["method"] == "GET"
      assert browse["http"]["path_template"] == "/v1/data/tags/:dataset"
      # "none" would drop the bearer and silently 404 the read (the doc.query
      # bug class) — both endpoints 404 anon, so they are read-tier.
      assert browse["auth_tier"] == "read"
      assert browse["scoped_prefix"] == "/w/:workspace_slug/p/:project_slug"

      docs = Enum.find(manifest["commands"], &(&1["id"] == "tag.docs"))
      assert docs != nil, "tag.docs not found in manifest"
      assert docs["http"]["method"] == "GET"
      assert docs["http"]["path_template"] == "/v1/data/tags/:dataset/:tag"
      assert docs["auth_tier"] == "read"
      assert "tag" in Enum.map(docs["args"], & &1["name"])
      assert docs["scoped_prefix"] == "/w/:workspace_slug/p/:project_slug"
    end
  end
end
