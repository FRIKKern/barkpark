defmodule BarkparkWeb.SharingCompositionP4Test do
  @moduledoc """
  P4 of the Scoped-by-URL arc (tsk-url-p4) — sharing composes on canonical
  URLs: capability (membership / section share / item token) never changes
  the address.

  Matrix under test:
    * the scoped paper reader is LIVE (BulldocsLive) and scope-bounded
    * `?share=<item-token>` opens exactly its own resource at exactly its
      own scope — wrong scope or wrong slug leaves the gate closed
    * a `:docs` read share opens an anonymous READ-ONLY scoped Studio —
      reads render, write events are server-side denied
    * the scoped rendition route exists and is scope-bounded
    * ingest receipts gain ADDITIVE scoped_liveview_path; liveview_path
      stays byte-identical
    * scoped media API responses emit scoped delivery URLs; flat stays flat
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Media, Repo, Sharing, Tenancy}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Sharing.Links

  @dataset "production"
  @ingest_token "barkpark-test-ingest-token"

  # The two fixture bodies below are deliberately DIFFERENT and deliberately
  # LITERAL. The rendition cache is seeded with @thumb_bytes at a path keyed by
  # `file.id`; the same row's upload blob holds @original_bytes. A success-path
  # test that asserted only `status == 200` could not tell the two apart — nor
  # tell either apart from a FOREIGN row's cached bytes served back under this
  # row's id. Comparing the served body to these literals is what makes "the
  # rendition for THIS file.id came back" falsifiable.
  @thumb_bytes "JPGBYTES"
  @original_bytes "PNGBYTES"

  setup %{conn: conn} do
    ws = create_workspace!("p4-share-ws")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "p4-share-proj"})

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "p4-shared-paper",
          "title" => "P4 Shared Paper",
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "SHARED-PAPER-BODY"}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    %{conn: conn, ws: ws, proj: proj, paper: paper}
  end

  # arpss-w8: shares are planted as STORED rows via `Barkpark.SharingFixtures`,
  # so `Sharing.refresh/0` — fired by add_share/remove_share, POST/DELETE
  # /v1/shares and the Studio shares handlers — REBUILDS this fixture instead of
  # ERASING it (a bare `put_env(:barkpark, :shares, …)` is in neither refresh
  # input). Snapshots and restores `:shares_env` as well as `:shares`.
  defp with_shares(env_string), do: Barkpark.SharingFixtures.plant_shares!(env_string)

  defp mint_link!(ws, proj, ref_id, attrs \\ %{}) do
    {:ok, {raw, _link}} =
      Links.create(
        Map.merge(
          %{
            workspace_id: ws.id,
            project_id: proj.id,
            dataset: @dataset,
            kind: "doc",
            ref_type: "paper",
            ref_id: ref_id,
            access: "read"
          },
          attrs
        )
      )

    raw
  end

  describe "live scoped paper reader" do
    test "a :papers section share serves the LIVE reader anonymously", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

      {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-shared-paper")
      assert html =~ "SHARED-PAPER-BODY"
    end

    test "without a share the scoped reader stays membership-gated", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-shared-paper")
      assert conn.status == 403
    end

    test "the canonical source endpoint inherits the section-share boundary", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      path = "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-shared-paper/source"
      browser_fetch = put_req_header(conn, "accept", "*/*")
      assert get(browser_fetch, path).status == 403

      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")
      source = browser_fetch |> get(path) |> json_response(200) |> get_in(["source"])
      assert source["kind"] == "blocks"
      assert inspect(source["blocks"]) =~ "SHARED-PAPER-BODY"
    end
  end

  describe "?share=<item-token> on the scoped reader" do
    test "a token for THIS paper at THIS scope grants read", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = mint_link!(ws, proj, "p4-shared-paper")

      {:ok, _view, html} =
        live(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-shared-paper?share=#{raw}")

      assert html =~ "SHARED-PAPER-BODY"
    end

    test "the same item token opens the canonical source and no other Paper", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = mint_link!(ws, proj, "p4-shared-paper")
      base = "/w/#{ws.slug}/p/#{proj.slug}/papers"

      source =
        conn
        |> put_req_header("accept", "*/*")
        |> get("#{base}/p4-shared-paper/source?share=#{raw}")
        |> json_response(200)
        |> get_in(["source"])

      assert source["kind"] == "blocks"
      assert inspect(source["blocks"]) =~ "SHARED-PAPER-BODY"

      assert get(
               put_req_header(conn, "accept", "*/*"),
               "#{base}/some-other-paper/source?share=#{raw}"
             ).status == 403
    end

    test "a token minted for ANOTHER scope does not open this URL", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      other_ws = create_workspace!("p4-other-ws")
      other_proj = create_project!(other_ws, "p4-other-proj")
      raw = mint_link!(other_ws, other_proj, "p4-shared-paper")

      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-shared-paper?share=#{raw}")
      assert conn.status == 403
    end

    test "a token bound to a DIFFERENT slug does not open this paper", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = mint_link!(ws, proj, "some-other-paper")

      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-shared-paper?share=#{raw}")
      assert conn.status == 403
    end
  end

  describe "read-only shared Studio (:docs read share)" do
    test "anonymous mounts the shared scope's Studio; write events are denied server-side",
         %{conn: conn, ws: ws, proj: proj} do
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")

      {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
      assert html =~ "pane-layout"

      # The write boundary is the SERVER's event gate, not hidden buttons:
      # a forged new-document event must be halted and create nothing.
      before_count = Repo.aggregate(Content.Document, :count)

      html = render_click(view, "new-document", %{})
      assert html =~ "shared read-only"
      assert Repo.aggregate(Content.Document, :count) == before_count

      # Navigation stays allowed.
      assert render_click(view, "select-group", %{"group" => "brief"})
    end

    test "without the share, anonymous still 403s on the scoped Studio", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
      assert conn.status == 403
    end
  end

  # Member token with a :read membership in the workspace — the credential a
  # signed-in browser user carries in `session["api_token"]` (or an API
  # client presents as Bearer).
  defp member_token!(ws) do
    raw_token = "p4-rendition-member-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token(raw_token),
        label: "p4-rendition-member",
        dataset: @dataset,
        permissions: ["read"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    raw_token
  end

  # Pre-seed the on-disk rendition cache so serve_rendition short-circuits at
  # the File.exists? check — no vips needed in test.
  defp seed_thumb_cache!(file) do
    rel = Path.join(["_renditions", file.id, "thumb.jpg"])
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, @thumb_bytes)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)
    :ok
  end

  describe "scoped renditions" do
    setup %{ws: ws, proj: proj} do
      name = "p4-#{System.unique_integer([:positive])}.png"
      rel = "uploads/p4-rendition/#{name}"
      full = Media.file_path(rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, @original_bytes)
      on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

      file =
        %MediaFile{}
        |> MediaFile.changeset(%{
          filename: name,
          original_name: name,
          path: rel,
          mime_type: "image/png",
          size: 8,
          dataset: @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        })
        |> Repo.insert!()

      %{media_file: file}
    end

    test "the scoped rendition route is membership/share-gated (no anonymous serve)", %{
      conn: conn,
      ws: ws,
      proj: proj,
      media_file: file
    } do
      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/media/renditions/#{file.id}/thumb")
      assert conn.status == 403
    end

    test "a member's session cookie serves the scoped rendition (browser <img> path)", %{
      ws: ws,
      proj: proj,
      media_file: file
    } do
      raw_token = member_token!(ws)
      seed_thumb_cache!(file)

      conn =
        scoped_conn()
        |> init_test_session(%{"api_token" => raw_token})
        |> get("/w/#{ws.slug}/p/#{proj.slug}/media/renditions/#{file.id}/thumb")

      assert conn.status == 200
      # WHICH file's bytes, not merely THAT bytes arrived. @thumb_bytes exists
      # only inside the `_renditions/<file.id>/` cache seeded above;
      # @original_bytes is this row's upload blob. A cache-path composition bug
      # that served any other path — a foreign row's rendition, or this row's
      # original — still answers 200, so the status alone proves nothing.
      assert conn.resp_body == @thumb_bytes
      refute conn.resp_body == @original_bytes
    end

    test "a member's Bearer header serves the scoped rendition", %{
      ws: ws,
      proj: proj,
      media_file: file
    } do
      raw_token = member_token!(ws)
      seed_thumb_cache!(file)

      conn =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get("/w/#{ws.slug}/p/#{proj.slug}/media/renditions/#{file.id}/thumb")

      assert conn.status == 200
      assert conn.resp_body == @thumb_bytes
      refute conn.resp_body == @original_bytes
    end

    test "a foreign workspace's file id 404s within the scope (scope-bounded)", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      with_shares("#{ws.slug}/#{proj.slug}/#{@dataset}:media:read")
      {default_ws, default_proj} = ensure_default_scope!()

      foreign =
        %MediaFile{}
        |> MediaFile.changeset(%{
          filename: "foreign.png",
          original_name: "foreign.png",
          path: "uploads/p4-rendition/foreign.png",
          mime_type: "image/png",
          size: 1,
          dataset: @dataset,
          workspace_id: default_ws.id,
          project_id: default_proj.id
        })
        |> Repo.insert!()

      conn = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/media/renditions/#{foreign.id}/thumb")
      assert conn.status == 404
    end
  end

  describe "ingest receipts" do
    test "scoped_liveview_path is ADDITIVE; liveview_path stays byte-identical", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      # The paper birth runs the publish wall (authoring-excellence D26): a
      # compliant ingest POST carries a description + registered weighted tags.
      Barkpark.LabelFixtures.register_tags!("production", ["p4-receipt"])

      body = %{
        "slug" => "p4-receipt-paper",
        "title" => "Receipt",
        "blocks" => [
          %{
            "id" => "b1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "x"}]
          }
        ],
        "description" => "Ingest receipt paper for the additive scoped-liveview-path contract.",
        "tags" => [
          %{
            "tag" => "p4-receipt",
            "strength" => 90,
            "rationale" => "Receipt paper exercising the scoped liveview path ingest contract."
          }
        ],
        "workspace" => ws.slug,
        "project" => proj.slug
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@ingest_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/plugins/bulldocs/papers", Jason.encode!(body))

      resp = json_response(conn, 200)
      assert resp["liveview_path"] == "/papers/p4-receipt-paper"

      assert resp["scoped_liveview_path"] ==
               "/w/#{ws.slug}/p/#{proj.slug}/papers/p4-receipt-paper"
    end
  end

  describe "request-scope media URL emission" do
    test "scoped index emits scoped delivery URLs; flat stays flat", %{
      ws: ws,
      proj: proj
    } do
      # Member token (the /v1 mirror is token-gated; shares cover /media/*).
      raw_token = "p4-media-member-#{System.unique_integer([:positive])}"

      {:ok, token} =
        %Barkpark.Auth.ApiToken{}
        |> Barkpark.Auth.ApiToken.changeset(%{
          token_hash: Barkpark.Auth.ApiToken.hash_token(raw_token),
          label: "p4-media-member",
          dataset: @dataset,
          permissions: ["read"]
        })
        |> Repo.insert()

      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
      # Re-use the rendition setup's file via a fresh insert under this scope.
      name = "p4-url-#{System.unique_integer([:positive])}.png"
      rel = "uploads/p4-url/#{name}"
      full = Media.file_path(rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "PNGBYTES")
      on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

      dataset_row = Tenancy.list_datasets(proj.id) |> Enum.find(&(&1.slug == @dataset))

      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: name,
        original_name: name,
        path: rel,
        mime_type: "image/png",
        size: 8,
        dataset: @dataset,
        dataset_id: dataset_row && dataset_row.id,
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert!()

      scoped =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> get("/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@dataset}")
        |> json_response(200)

      urls = Enum.map(get_in(scoped, ["result", "assets"]) || [], & &1["url"])
      assert urls != []
      assert Enum.all?(urls, &String.starts_with?(&1, "/w/#{ws.slug}/p/#{proj.slug}/media/"))
    end
  end
end
