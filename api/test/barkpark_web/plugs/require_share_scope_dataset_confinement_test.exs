defmodule BarkparkWeb.Plugs.RequireShareScopeDatasetConfinementTest do
  @moduledoc """
  task-4f26838232b5ece0 — a `?dataset=` query parameter must not escape the
  dataset a share was minted for.

  The split under test is "guard before derivation": `RequireShareScope` used
  to read `conn.path_params["dataset"]`, but FOUR share-reachable routes carry
  no `:dataset` path segment and their controllers derive the dataset from the
  MERGED params, i.e. from the query string —

    * `GET /w/:ws/p/:proj/papers/:slug/source`  (BulldocsSourceController)
    * `GET /w/:ws/p/:proj/papers/:slug/email`   (BulldocsEmailController)
    * `GET /w/:ws/p/:proj/media/`               (MediaController.index/2)
    * `GET /w/:ws/p/:proj/media/:id/meta`       (MediaController.show/2, via
      `render_file/2`, which resolves `assetDocId` in `conn.params["dataset"]`)

  — so the guard always compared `"production"` while the read went elsewhere.

  Every refusal case below is paired with a control on the SAME route proving
  the route serves 200 when the dataset matches: a bare 403 is not evidence
  unless the 200 is reachable next to it.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Sharing, Tenancy}
  alias Barkpark.Sharing.Links

  @shared_dataset "production"
  @unshared_dataset "staging"

  setup %{conn: conn} do
    ws = create_workspace!("confine-ds-ws")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "confine-ds-proj"})

    {:ok, _shared_paper} = put_paper(ws, proj, @shared_dataset, "PRODUCTION-ONLY-BODY")
    {:ok, _other_paper} = put_paper(ws, proj, @unshared_dataset, "STAGING-ONLY-BODY")

    # `Media.Delivery.Search` filters the blob table on `m.dataset_id`
    # authoritatively whenever the dataset STRING resolves to a real row, so
    # both fixtures need their Dataset row and the FK set — otherwise both
    # listings come back empty and the media assertions pass vacuously.
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @unshared_dataset, name: @unshared_dataset})
    shared_ds = Tenancy.get_dataset(proj, @shared_dataset)
    unshared_ds = Tenancy.get_dataset(proj, @unshared_dataset)

    {:ok, shared_file} =
      create_media_file_in!(
        ws,
        proj,
        %{filename: "prod-asset.png", dataset_id: shared_ds.id},
        @shared_dataset
      )

    {:ok, unshared_file} =
      create_media_file_in!(
        ws,
        proj,
        %{filename: "staging-asset.png", dataset_id: unshared_ds.id},
        @unshared_dataset
      )

    %{
      conn: put_req_header(conn, "accept", "*/*"),
      ws: ws,
      proj: proj,
      shared_file: shared_file,
      unshared_file: unshared_file
    }
  end

  # The SAME slug in both datasets, with a body string unique per dataset — so
  # an assertion on the served body names WHICH dataset the read resolved to,
  # not merely whether the request was allowed.
  defp put_paper(ws, proj, dataset, marker) do
    Content.upsert_paper(
      Barkpark.LabelFixtures.paper_attrs(%{
        "slug" => "confine-ds-paper",
        "title" => "Confinement Paper",
        "dataset" => dataset,
        "blocks" => [
          %{
            "id" => "b1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => marker}]
          }
        ],
        "workspace_id" => ws.id,
        "project_id" => proj.id
      }),
      dataset: dataset
    )
  end

  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  defp share_for(ws, proj, dataset, surface),
    do: with_shares("#{ws.slug}/#{proj.slug}/#{dataset}:#{surface}:read")

  defp base(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}"

  # The refusal shape the neighbouring confined routes already use: no grant,
  # so `ResolveWorkspace`'s membership gate denies the anonymous caller. This
  # asserts the SHAPE (never a 2xx) rather than pinning one status code, so it
  # stays true for both the 403 and 404 arms of that gate.
  defp assert_refused(conn) do
    assert conn.status in [401, 403, 404],
           "expected the share gate to refuse, got #{conn.status}"

    conn
  end

  describe "papers surface — /papers/:slug/source" do
    test "?dataset= naming an UNSHARED dataset is refused", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @shared_dataset, "papers")

      refused =
        conn
        |> get("#{base(ws, proj)}/papers/confine-ds-paper/source?dataset=#{@unshared_dataset}")
        |> assert_refused()

      refute refused.resp_body =~ "STAGING-ONLY-BODY"
    end

    test "the same route without the query param still serves the SHARED dataset", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @shared_dataset, "papers")

      body = conn |> get("#{base(ws, proj)}/papers/confine-ds-paper/source") |> response(200)

      assert body =~ "PRODUCTION-ONLY-BODY"
      refute body =~ "STAGING-ONLY-BODY"
    end

    test "when the share IS for that dataset, ?dataset= resolves to it and serves it", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      # Only staging is shared. A 200 carrying STAGING-ONLY-BODY proves the
      # guard compared "staging" (it had no production share to match) AND the
      # controller resolved "staging" — the two sides read the same value.
      share_for(ws, proj, @unshared_dataset, "papers")

      body =
        conn
        |> get("#{base(ws, proj)}/papers/confine-ds-paper/source?dataset=#{@unshared_dataset}")
        |> response(200)

      assert body =~ "STAGING-ONLY-BODY"
      refute body =~ "PRODUCTION-ONLY-BODY"
    end

    test "a PATH dataset wins over a decoy ?dataset= on both sides of the gate", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @shared_dataset, "papers")

      body =
        conn
        |> get(
          "#{base(ws, proj)}/d/#{@shared_dataset}/papers/confine-ds-paper/source" <>
            "?dataset=#{@unshared_dataset}"
        )
        |> response(200)

      assert body =~ "PRODUCTION-ONLY-BODY"
      refute body =~ "STAGING-ONLY-BODY"
    end

    test "a malformed ?dataset[]= resolves to the default on both sides", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @shared_dataset, "papers")

      # `?dataset[]=staging` decodes to a LIST. Both the guard and
      # `requested_dataset/1` clamp a non-binary to the default, so this stays
      # a production read rather than becoming an over-block or a 500.
      body =
        conn
        |> get("#{base(ws, proj)}/papers/confine-ds-paper/source?dataset[]=#{@unshared_dataset}")
        |> response(200)

      assert body =~ "PRODUCTION-ONLY-BODY"
    end
  end

  describe "papers surface — /papers/:slug/email" do
    test "?dataset= naming an UNSHARED dataset is refused", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @shared_dataset, "papers")

      refused =
        conn
        |> get("#{base(ws, proj)}/papers/confine-ds-paper/email?dataset=#{@unshared_dataset}")
        |> assert_refused()

      refute refused.resp_body =~ "STAGING-ONLY-BODY"
    end

    test "the same route without the query param still serves the SHARED dataset", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @shared_dataset, "papers")

      body = conn |> get("#{base(ws, proj)}/papers/confine-ds-paper/email") |> response(200)

      assert body =~ "PRODUCTION-ONLY-BODY"
      refute body =~ "STAGING-ONLY-BODY"
    end

    test "when the share IS for that dataset, ?dataset= resolves to it and serves it", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      share_for(ws, proj, @unshared_dataset, "papers")

      body =
        conn
        |> get("#{base(ws, proj)}/papers/confine-ds-paper/email?dataset=#{@unshared_dataset}")
        |> response(200)

      assert body =~ "STAGING-ONLY-BODY"
      refute body =~ "PRODUCTION-ONLY-BODY"
    end
  end

  describe "media surface — /media/ (index)" do
    test "?dataset= naming an UNSHARED dataset is refused", ctx do
      %{conn: conn, ws: ws, proj: proj, unshared_file: unshared_file} = ctx
      share_for(ws, proj, @shared_dataset, "media")

      refused =
        conn
        |> get("#{base(ws, proj)}/media/?dataset=#{@unshared_dataset}")
        |> assert_refused()

      refute refused.resp_body =~ unshared_file.filename
    end

    test "the same route without the query param still lists the SHARED dataset", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared, unshared_file: unshared} = ctx
      share_for(ws, proj, @shared_dataset, "media")

      body = conn |> get("#{base(ws, proj)}/media/") |> json_response(200)
      names = Enum.map(body["files"], & &1["filename"])

      assert shared.filename in names
      refute unshared.filename in names
    end

    test "when the share IS for that dataset, ?dataset= resolves to it and lists it", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared, unshared_file: unshared} = ctx
      share_for(ws, proj, @unshared_dataset, "media")

      body =
        conn
        |> get("#{base(ws, proj)}/media/?dataset=#{@unshared_dataset}")
        |> json_response(200)

      names = Enum.map(body["files"], & &1["filename"])

      assert unshared.filename in names
      refute shared.filename in names
    end
  end

  describe "media surface — /media/:id/meta (show)" do
    # The fourth route, not named in the row: `show/2` takes no `dataset`
    # itself, but `render_file/2` reads `conn.params["dataset"]` to resolve the
    # `assetDocId`, so the query param reaches an unshared dataset here too.
    test "?dataset= naming an UNSHARED dataset is refused", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared} = ctx
      share_for(ws, proj, @shared_dataset, "media")

      conn
      |> get("#{base(ws, proj)}/media/#{shared.id}/meta?dataset=#{@unshared_dataset}")
      |> assert_refused()
    end

    test "the same route without the query param still serves the SHARED dataset", ctx do
      %{conn: conn, ws: ws, proj: proj, shared_file: shared} = ctx
      share_for(ws, proj, @shared_dataset, "media")

      body =
        conn
        |> get("#{base(ws, proj)}/media/#{shared.id}/meta")
        |> json_response(200)

      assert body["filename"] == shared.filename
    end
  end

  describe "item share link (?share=<token>)" do
    test "an item link cannot be dataset-pivoted with ?dataset=", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      raw = mint_link!(ws, proj, @shared_dataset, "confine-ds-paper")

      refused =
        conn
        |> get(
          "#{base(ws, proj)}/papers/confine-ds-paper/source" <>
            "?share=#{raw}&dataset=#{@unshared_dataset}"
        )
        |> assert_refused()

      refute refused.resp_body =~ "STAGING-ONLY-BODY"
    end

    test "an item link minted for a NON-default dataset opens its own resource", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      # Before the fix the guard always compared "production" here, so a link
      # minted for staging could never open anything — a false NEGATIVE that
      # rode on the same defect. It now opens exactly its bound resource.
      raw = mint_link!(ws, proj, @unshared_dataset, "confine-ds-paper")

      body =
        conn
        |> get(
          "#{base(ws, proj)}/papers/confine-ds-paper/source" <>
            "?share=#{raw}&dataset=#{@unshared_dataset}"
        )
        |> response(200)

      assert body =~ "STAGING-ONLY-BODY"
    end

    test "that staging link still does NOT open the production paper", ctx do
      %{conn: conn, ws: ws, proj: proj} = ctx
      raw = mint_link!(ws, proj, @unshared_dataset, "confine-ds-paper")

      refused =
        conn
        |> get("#{base(ws, proj)}/papers/confine-ds-paper/source?share=#{raw}")
        |> assert_refused()

      refute refused.resp_body =~ "PRODUCTION-ONLY-BODY"
    end
  end

  defp mint_link!(ws, proj, dataset, ref_id) do
    {:ok, {raw, _link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: dataset,
        kind: "doc",
        ref_type: "paper",
        ref_id: ref_id,
        access: "read"
      })

    raw
  end
end
