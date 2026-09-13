defmodule BarkparkWeb.MediaShareAffordanceTest do
  @moduledoc """
  The operator affordance after the task-8627e1a3f974693d ruling
  (task-cbb112a9b4c600cc).

  THE RULING, not re-derived here: anonymous reads of a NON-Default tenant's
  scoped media are granted ONLY by a `:read` share on the scope for the
  `:media` surface (`BarkparkWeb.Plugs.RequireShareScope` moduledoc). Route
  admission never reads `bp_visibility`.

  So this file proves two things about the affordance built on top of it:

    * c0 — the `public` option's copy says `public` means readable WITHIN this
      scope's sharing, and both surfaces (`bp media get`'s output and the
      Studio media library) report the scope's live `:media` share state, for a
      shared AND an unshared scope.
    * c1 — ONE verb (`POST /v1/shares/media`, behind `bp share publish-media`)
      and ONE Studio action (`"publish_scope_media"`) create the share, and
      after it runs an anonymous scoped rendition GET is 200 for a public asset
      and STILL 403 for a `bp_visibility: "private"` one. The private arm is
      what makes the remedy falsifiable: an affordance that flipped visibility
      instead of creating the share would serve the private asset too.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Sharing
  alias Barkpark.Tenancy
  alias BarkparkWeb.MediaVisibilityCopy

  @dataset "production"
  @thumb_bytes "AFFORDANCE-THUMB"

  setup do
    ws = create_workspace!("affordance-ws")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "affordance-proj"})

    # No share planted in setup — the UNSHARED scope is the default state every
    # test either asserts on or explicitly leaves behind.
    Barkpark.SharingFixtures.plant_shares!("")

    %{ws: ws, proj: proj}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp put_media!(ws, proj) do
    name = "affordance-#{System.unique_integer([:positive])}.png"
    rel = "uploads/media-share-affordance/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "ORIGINAL")
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

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

  # The `mediaAsset` document straight through the changeset — `bp_visibility`
  # is the only key under test, and `Access.visibility/1` reads exactly it.
  defp link_asset!(file, ws, proj, visibility) do
    suffix = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "affordance-asset-#{suffix}",
        type: "mediaAsset",
        dataset: @dataset,
        title: "affordance asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => file.id, "bp_visibility" => visibility},
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert()

    doc
  end

  defp admin_token!(ws) do
    raw = "affordance-admin-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Barkpark.Auth.create_token(raw, "affordance-admin", @dataset, ["read", "admin"])

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "admin")
    raw
  end

  defp scope(ws, proj), do: "#{ws.slug}/#{proj.slug}/#{@dataset}"

  defp rendition_path(ws, proj, file),
    do: "/w/#{ws.slug}/p/#{proj.slug}/media/renditions/#{file.id}/thumb"

  defp asset_path(ws, proj, file),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@dataset}/#{file.id}"

  defp studio_media_path(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media"

  defp signed_in(raw_token) do
    scoped_conn()
    |> post("/login", %{"token" => raw_token})
    |> recycle()
  end

  # ── c0: the public option stops over-promising ──────────────────────────

  describe "c0 — the public visibility option's copy and the scope's :media share state" do
    test "both surfaces state scope-bounded public and read the share state, shared and unshared",
         %{ws: ws, proj: proj} do
      file = put_media!(ws, proj)
      raw = admin_token!(ws)

      # --- UNSHARED scope -------------------------------------------------
      refute Sharing.media_shared?(ws.slug, proj.slug, @dataset)

      bp_unshared =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(asset_path(ws, proj, file))
        |> json_response(200)
        |> bp_media_get_notice()

      # bp's asset output states, in its OWN copy, what `public` promises …
      assert bp_unshared["copy"] =~ "readable within this scope's sharing"
      assert bp_unshared["copy"] =~ "only while"
      assert bp_unshared["label"] == MediaVisibilityCopy.public_label()
      # … and never offers the visibility field as the remedy.
      assert bp_unshared["remedy"] =~ "publish-media"
      assert bp_unshared["remedy"] =~ "creates the :media :read share"
      assert bp_unshared["remedy"] =~ "Never flip an asset's visibility"
      # … and reports the scope's LIVE share state.
      assert bp_unshared["scope"] == scope(ws, proj)
      assert bp_unshared["media_shared"] == false
      assert bp_unshared["media_share_state"] =~ "not shared"

      studio_unshared = studio_media_html(raw, ws, proj)
      assert studio_unshared =~ "readable within this scope&#39;s sharing"
      assert studio_unshared =~ "not shared"

      # --- SHARED scope ---------------------------------------------------
      Barkpark.SharingFixtures.plant_shares!("#{scope(ws, proj)}:media:read")
      assert Sharing.media_shared?(ws.slug, proj.slug, @dataset)

      bp_shared =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(asset_path(ws, proj, file))
        |> json_response(200)
        |> bp_media_get_notice()

      # The COPY is identical (it is one module's sentence, not per-state
      # prose); only the share-state read moves.
      assert bp_shared["copy"] == bp_unshared["copy"]
      assert bp_shared["media_shared"] == true
      assert bp_shared["media_share_state"] =~ "this scope carries a :media share"
      refute bp_shared["media_share_state"] =~ "NO :media share"

      studio_shared = studio_media_html(raw, ws, proj)
      assert studio_shared =~ "readable within this scope&#39;s sharing"
      assert studio_shared =~ "this scope carries a :media share"
    end
  end

  # WHAT `bp media get` ACTUALLY READS, and the reason this is not a plain
  # `Map.fetch!(body, "visibility")`.
  #
  # bp's Go client renders every successful body through `unwrapResult`
  # (internal/cli/run.go): it returns the body's `result` value and DROPS every
  # top-level sibling. A notice that rides BESIDE `result` is in the JSON and
  # invisible to `bp media get` — c0 ("in bp's media/asset output, in its own
  # copy") would be unmet in practice while a raw-JSON assertion stayed green.
  #
  # So this helper reproduces the unwrap — take `result`, then read the notice
  # out of it — and additionally refuses the old placement outright. Move the
  # key back beside `result` and BOTH halves red.
  defp bp_media_get_notice(body) do
    refute Map.has_key?(body, "visibility"),
           "the visibility notice must not ride beside `result`: bp's unwrapResult " <>
             "keeps only `result`, so a top-level key never reaches `bp media get`"

    unwrapped = Map.fetch!(body, "result")

    # The notice is a SIBLING of the asset's own delivery-tier `visibility`
    # string inside `result`, never a replacement for it — reusing that name
    # would change an existing field's type.
    assert Map.has_key?(unwrapped, "visibility")
    refute is_map(unwrapped["visibility"])

    Map.fetch!(unwrapped, "visibilityNotice")
  end

  defp studio_media_html(raw_token, ws, proj) do
    {:ok, _view, html} = live(signed_in(raw_token), studio_media_path(ws, proj))
    html
  end

  # ── c1: one verb / one action, and what it actually opens ───────────────

  describe "c1 — the affordance creates the :media :read share" do
    setup %{ws: ws, proj: proj} do
      public_file = put_media!(ws, proj)
      private_file = put_media!(ws, proj)
      seed_thumb_cache!(public_file)
      seed_thumb_cache!(private_file)
      link_asset!(public_file, ws, proj, "public")
      link_asset!(private_file, ws, proj, "private")

      %{public_file: public_file, private_file: private_file}
    end

    test "after the bp verb runs, anonymous rendition GET is 200 for a public asset and 403 for a private one",
         %{ws: ws, proj: proj, public_file: public_file, private_file: private_file} do
      raw = admin_token!(ws)

      # PRECONDITION, not a control: with no share the PUBLIC asset is 403 too,
      # so the 200 below is attributable to the share and to nothing else.
      assert scoped_conn() |> get(rendition_path(ws, proj, public_file)) |> Map.get(:status) ==
               403

      # THE ONE VERB (`bp share publish-media <scope>` drives exactly this).
      created =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post("/v1/shares/media", %{"scope" => scope(ws, proj)})
        |> json_response(201)

      assert created["share"]["surfaces"] == ["media"]
      assert created["share"]["access"] == "read"
      assert created["share"]["source"] == "stored"
      assert created["visibility"]["media_shared"] == true

      # BOTH ARMS, ONE TEST.
      public_resp = scoped_conn() |> get(rendition_path(ws, proj, public_file))
      assert public_resp.status == 200
      assert public_resp.resp_body == @thumb_bytes

      private_resp = scoped_conn() |> get(rendition_path(ws, proj, private_file))

      assert private_resp.status == 403,
             "a bp_visibility private asset must stay 403 — the share admits the SCOPE, " <>
               "the per-asset clamp still applies"

      refute private_resp.resp_body == @thumb_bytes
    end

    test "the Studio media library action creates the same :media :read share", %{
      ws: ws,
      proj: proj,
      public_file: public_file
    } do
      raw = admin_token!(ws)
      refute Sharing.media_shared?(ws.slug, proj.slug, @dataset)

      {:ok, view, _html} = live(signed_in(raw), studio_media_path(ws, proj))
      render_click(view, "publish_scope_media", %{})

      assert Sharing.media_shared?(ws.slug, proj.slug, @dataset)
      assert Sharing.access_for(ws.slug, proj.slug, @dataset) == :read

      assert scoped_conn() |> get(rendition_path(ws, proj, public_file)) |> Map.get(:status) ==
               200
    end

    test "the affordance writes the SHARE and never an asset's bp_visibility", %{
      ws: ws,
      proj: proj,
      private_file: private_file
    } do
      raw = admin_token!(ws)
      before = Media.asset_doc_for_file(private_file, @dataset)

      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> post("/v1/shares/media", %{"scope" => scope(ws, proj)})
      |> json_response(201)

      after_doc = Media.asset_doc_for_file(private_file, @dataset)
      assert after_doc.content["bp_visibility"] == "private"
      assert after_doc.content == before.content
      assert after_doc.rev == before.rev
    end
  end
end
