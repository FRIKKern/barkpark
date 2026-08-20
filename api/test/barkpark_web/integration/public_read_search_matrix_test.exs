defmodule BarkparkWeb.Integration.PublicReadSearchMatrixTest do
  @moduledoc """
  ROUTED public-read × perspective matrix over the FOUR draft-capable read
  entry points the AnonPerspective chokepoint seals
  (stw7-backlog-drafts-clamp-gap, charter D60/D61):

    * SCOPED search      GET /w/:ws/p/:proj/v1/data/search/:dataset
    * SCOPED federated   GET /w/:ws/p/:proj/v1/search/:dataset
    * FLAT federated     GET /v1/search/:dataset            (bare `:api`)
    * SCOPED paper-source GET /w/:ws/p/:proj/d/:ds/papers/:slug/source

  None of these four pipelines mounts `Plugs.PublicRead` (its allowed_route?
  whitelists query/doc only — mounting it would 403 scoped search outright and
  take the live flagship dark, D49), so the ONLY clamp is
  `AnonPerspective.anon_pinned?/1` pinning a public-read-carrying token to
  `:published`. This suite proves the pin through the REAL router.

  ## Why the MIXED-list token is the load-bearing case

  `TokenController` allowlists `~w(public-read read)` and mints the caller's
  permissions list VERBATIM and UNORDERED through the PUBLIC site-provisioning
  path, so `["public-read", "read"]` is a real-world browser-shipped token. An
  implementation pinning `permissions == ["public-read"]` passes every
  singleton-token test and still leaks drafts to the mixed token — the exact
  vacuous-green shape the reopened p0 exists to correct. Each route therefore
  runs the mixed token, and scoped search additionally runs the singleton.

  ## The matrix can fail

  Every describe carries an admin-token CONTROL asserting the same route DOES
  serve the seeded draft to a non-public-read member — proving the seed is
  leak-observable, so a green public-read case means the pin held, not that
  the draft was invisible to everyone.

  ## Fail-closed is not fail-broken

  Public-read with NO perspective param (and even WITH `perspective=drafts` —
  the pin is a silent downgrade, never a 403) still returns 200 with the
  published row on every route.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  import Barkpark.TenancyFixtures

  @dataset "production"

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp mint!(label, perms, ws_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, perms, ws_id)
    raw
  end

  defp search_ids(conn, path) do
    body = conn |> get(path) |> json_response(200)
    Enum.map(body["documents"], & &1["_id"])
  end

  defp federated_ids(conn, path) do
    body = conn |> get(path) |> json_response(200)

    body
    |> get_in(["results", "documents", "hits"])
    |> Kernel.||([])
    |> Enum.map(& &1["_id"])
  end

  defp refute_draft_rows(ids) do
    leaked = Enum.filter(ids, &String.starts_with?(&1, "drafts."))
    assert leaked == [], "public-read token received draft rows: #{inspect(leaked)}"
  end

  # ── SCOPED routes: search + federated + paper-source ──────────────────────
  describe "scoped routes — a public-read-carrying token gets no draft rows" do
    setup do
      ws = create_workspace!("prsm-ws")
      proj = create_project!(ws, "prsm-proj")
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      # A published row and a DRAFT-ONLY row, both matching the probe query.
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "mx-pub", "title" => "Quaggasearch Live Row"},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document("mx-pub", "post", @dataset, scope)

      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "mx-draft", "title" => "Quaggasearch Secret Draft"},
          @dataset,
          scope
        )

      # A published paper whose DRAFT twin then diverged — the draft-overlay
      # leak is observable via both the returned id and the blocks.
      slug = "prsm-paper"

      published_blocks = [
        %{"id" => "pb", "type" => "paragraph", "text" => "Published paper source"}
      ]

      draft_blocks = [
        %{"id" => "db", "type" => "paragraph", "text" => "SECRET draft paper source"}
      ]

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: @dataset,
            blocks: published_blocks,
            workspace_id: ws.id,
            project_id: proj.id
          })
        )

      {:ok, _} =
        Content.upsert_document(
          "paper",
          %{
            "doc_id" => "drafts." <> slug,
            "title" => "Draft title",
            "status" => "draft",
            "content" => %{"blocks" => draft_blocks}
          },
          @dataset,
          scope
        )

      mixed = mint!("prsm-mixed", ["public-read", "read"], ws.id)
      singleton = mint!("prsm-singleton", ["public-read"], ws.id)
      admin = mint!("prsm-admin", ["read", "write", "admin"], ws.id)

      %{
        ws: ws,
        proj: proj,
        mixed: mixed,
        singleton: singleton,
        admin: admin,
        slug: slug,
        published_blocks: published_blocks,
        draft_blocks: draft_blocks
      }
    end

    defp scoped(ws, proj, suffix), do: "/w/#{ws.slug}/p/#{proj.slug}#{suffix}"

    test "CONTROL: an admin member token DOES read the seeded drafts on all three routes", %{
      conn: conn,
      ws: ws,
      proj: proj,
      admin: admin,
      slug: slug,
      draft_blocks: draft_blocks
    } do
      ids =
        conn
        |> bearer(admin)
        |> search_ids(
          scoped(ws, proj, "/v1/data/search/#{@dataset}?q=quaggasearch&perspective=drafts")
        )

      assert "drafts.mx-draft" in ids,
             "seed is not leak-observable: admin+drafts did not surface the draft on scoped search"

      fed_ids =
        conn
        |> bearer(admin)
        |> federated_ids(
          scoped(
            ws,
            proj,
            "/v1/search/#{@dataset}?q=quaggasearch&surfaces=documents&perspective=drafts"
          )
        )

      assert "drafts.mx-draft" in fed_ids

      body =
        conn
        |> bearer(admin)
        |> put_req_header("accept", "*/*")
        |> get(scoped(ws, proj, "/d/#{@dataset}/papers/#{slug}/source?perspective=drafts"))
        |> json_response(200)

      assert body["id"] == "drafts." <> slug
      assert get_in(body, ["source", "blocks"]) == draft_blocks
    end

    test "scoped search: mixed public-read token + ?perspective=drafts is silently pinned", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      ids =
        conn
        |> bearer(mixed)
        |> search_ids(
          scoped(ws, proj, "/v1/data/search/#{@dataset}?q=quaggasearch&perspective=drafts")
        )

      refute_draft_rows(ids)
      # Silent downgrade, not 403 — the published row still comes back.
      assert "mx-pub" in ids
    end

    test "scoped search: ?perspective=raw is pinned too", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed
    } do
      ids =
        conn
        |> bearer(mixed)
        |> search_ids(
          scoped(ws, proj, "/v1/data/search/#{@dataset}?q=quaggasearch&perspective=raw")
        )

      refute_draft_rows(ids)
      assert "mx-pub" in ids
    end

    test "scoped search: singleton public-read token is pinned (no PublicRead plug on this pipeline)",
         %{conn: conn, ws: ws, proj: proj, singleton: singleton} do
      ids =
        conn
        |> bearer(singleton)
        |> search_ids(
          scoped(ws, proj, "/v1/data/search/#{@dataset}?q=quaggasearch&perspective=drafts")
        )

      refute_draft_rows(ids)
      assert "mx-pub" in ids
    end

    test "scoped search: NO perspective param still returns 200 with published rows (fail-closed, not fail-broken)",
         %{conn: conn, ws: ws, proj: proj, mixed: mixed} do
      ids =
        conn
        |> bearer(mixed)
        |> search_ids(scoped(ws, proj, "/v1/data/search/#{@dataset}?q=quaggasearch"))

      assert "mx-pub" in ids
      refute_draft_rows(ids)
    end

    test "scoped federated: mixed public-read token + drafts is pinned; no-perspective stays open",
         %{conn: conn, ws: ws, proj: proj, mixed: mixed} do
      ids =
        conn
        |> bearer(mixed)
        |> federated_ids(
          scoped(
            ws,
            proj,
            "/v1/search/#{@dataset}?q=quaggasearch&surfaces=documents&perspective=drafts"
          )
        )

      refute_draft_rows(ids)
      assert "mx-pub" in ids

      open_ids =
        conn
        |> bearer(mixed)
        |> federated_ids(
          scoped(ws, proj, "/v1/search/#{@dataset}?q=quaggasearch&surfaces=documents")
        )

      assert "mx-pub" in open_ids
    end

    test "scoped paper-source: mixed public-read token + drafts gets the PUBLISHED source", %{
      conn: conn,
      ws: ws,
      proj: proj,
      mixed: mixed,
      slug: slug,
      published_blocks: published_blocks
    } do
      body =
        conn
        |> bearer(mixed)
        |> put_req_header("accept", "*/*")
        |> get(scoped(ws, proj, "/d/#{@dataset}/papers/#{slug}/source?perspective=drafts"))
        |> json_response(200)

      # The draft twin exists (the CONTROL proves the route serves it to an
      # admin) — a public-read caller gets the published row, same 200 shape.
      assert body["id"] == slug
      assert get_in(body, ["source", "blocks"]) == published_blocks

      plain =
        conn
        |> bearer(mixed)
        |> put_req_header("accept", "*/*")
        |> get(scoped(ws, proj, "/d/#{@dataset}/papers/#{slug}/source"))
        |> json_response(200)

      assert plain["id"] == slug
    end
  end

  # ── FLAT federated route (bare :api — router's third entry point) ─────────
  describe "flat federated /v1/search — public-read token gets no draft rows" do
    setup do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "fmxpost", "title" => "FMXPost", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.create_document(
          "fmxpost",
          %{"_id" => "fmx-pub", "title" => "Zonkeysearch Live Row"},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document("fmx-pub", "fmxpost", @dataset, scope)

      {:ok, _} =
        Content.create_document(
          "fmxpost",
          %{"_id" => "fmx-draft", "title" => "Zonkeysearch Secret Draft"},
          @dataset,
          scope
        )

      %{
        mixed: mint!("prsm-flat-mixed", ["public-read", "read"], ws.id),
        admin: mint!("prsm-flat-admin", ["read", "write", "admin"], ws.id)
      }
    end

    test "CONTROL: an admin token DOES read the seeded draft on the flat federated route", %{
      conn: conn,
      admin: admin
    } do
      ids =
        conn
        |> bearer(admin)
        |> federated_ids(
          "/v1/search/#{@dataset}?q=zonkeysearch&surfaces=documents&perspective=drafts"
        )

      assert "drafts.fmx-draft" in ids,
             "seed is not leak-observable on the flat federated route"
    end

    test "mixed public-read token + ?perspective=drafts is silently pinned", %{
      conn: conn,
      mixed: mixed
    } do
      ids =
        conn
        |> bearer(mixed)
        |> federated_ids(
          "/v1/search/#{@dataset}?q=zonkeysearch&surfaces=documents&perspective=drafts"
        )

      refute_draft_rows(ids)
      assert "fmx-pub" in ids
    end

    test "NO perspective param still returns 200 with published rows", %{conn: conn, mixed: mixed} do
      ids =
        conn
        |> bearer(mixed)
        |> federated_ids("/v1/search/#{@dataset}?q=zonkeysearch&surfaces=documents")

      assert "fmx-pub" in ids
      refute_draft_rows(ids)
    end
  end
end
