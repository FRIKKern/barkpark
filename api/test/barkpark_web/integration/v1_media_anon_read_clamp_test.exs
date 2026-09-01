defmodule BarkparkWeb.Integration.V1MediaAnonReadClampTest do
  @moduledoc """
  ONE principal test, every `/v1/media` READ door — `task-d55b02001cf589f0`
  (the signing escalation) and `task-27d5fdba100d2bc6` brief item 3 (the
  ungated metadata read, filed LATENT and demonstrated here).

  ## The two defects share a module and a render path

  1. **Signing.** `V1.MediaController.render_opts/3` read the URL-signing
     switch straight off the query string:

         sign_urls: params["appendRequestSecret"] in ["true", "1"]

     No token, session, membership or permission was consulted. For a
     `bp_visibility: "token"` asset `Urls.maybe_sign/3` therefore minted a REAL
     `SignedUrl` into the JSON, and `Access.delivery_ok?("token", _auth,
     signed)` admits a signature ALONE — so an anonymous caller escalated from
     "I know an id" to BYTES by asking politely.

  2. **Metadata.** The versioned read path never called `Access.allowed?/4` at
     all, so `AssetResponse.render/3` emitted `filename` / `path` / `size` —
     and `visibility`, the tier it was not enforcing — for any asset, to anyone.
     `Envelope` redaction covers only the nested `asset` doc, never the blob row.

  The felix W14 fix landed `Access.allowed?/4` on ONE legacy door
  (`MediaController.show/2`, `:view`) and on none of its versioned siblings.

  ## Why these tests are shaped the way they are

  `Access.allowed?/4` is the remedy for a SINGLE-asset read (403). It is the
  wrong remedy for a LISTING, which must FILTER — a 403 on `GET /v1/media/:ds`
  would break every anonymous public-asset consumer, and a post-render filter
  would leave `count` lying. So the listing doors clamp inside the query, and
  the tests below assert the clamp on `count` as well as on the rows.

  DIRECTION OF CAPABILITY: every assertion here is that a MISSING credential
  costs access. A test that only asserted the authorised path still works would
  pass on the broken code, so each anonymous-negative is paired with — and kept
  separate from — its authorised-positive control.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content, Media, Tenancy}
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @ds "production"

  setup do
    Auth.create_token("anon-clamp-admin", "anon-clamp-admin", @ds, ["read", "write", "admin"])
    Auth.create_token("anon-clamp-read", "anon-clamp-read", @ds, ["read"])
    ensure_default_scope!()
    :ok
  end

  defp admin(conn), do: put_req_header(conn, "authorization", "Bearer anon-clamp-admin")
  defp read_token(conn), do: put_req_header(conn, "authorization", "Bearer anon-clamp-read")

  defp png_upload do
    path = Path.join(System.tmp_dir!(), "anonclamp-#{System.unique_integer([:positive])}.png")
    File.write!(path, Base.decode64!(@png_b64))
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "pixel.png", content_type: "image/png"}
  end

  # Upload an asset and set its visibility tier. Returns the created payload.
  defp asset_with_visibility(conn, visibility) do
    created =
      conn
      |> admin()
      |> post(~p"/v1/media/#{@ds}/upload", %{"file" => png_upload()})
      |> json_response(201)

    id = created["result"]["id"]

    conn
    |> admin()
    |> patch(~p"/v1/media/#{@ds}/#{id}", %{"bp_visibility" => visibility})
    |> json_response(200)

    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
      Media.Renditions.delete_for_file(id)
      Assets.delete_for_blob(id, @ds)
    end)

    created["result"]
  end

  # What an ANONYMOUS caller gets back from the single-asset read, normalised so
  # the assertion is indifferent to WHICH honest answer the fix chose: a refusal
  # (`{:refused, status}`) and an unsigned URL are both correct; a signature is
  # not.
  defp anon_show(id, query \\ "") do
    conn = get(build_conn(), "/v1/media/#{@ds}/#{id}#{query}")

    case conn.status do
      200 -> {:ok, json_response(conn, 200)["result"]}
      status -> {:refused, status}
    end
  end

  defp signed?(url) when is_binary(url), do: String.contains?(url, "_=")
  defp signed?(_), do: false

  defp ids(result), do: Enum.map(result["assets"] || result["hits"] || [], & &1["id"])

  # A green positive control is silent, and a silent positive control is
  # indistinguishable from one that was never run — which is exactly how a
  # security fix quietly becomes a denial of service against its own users.
  # These two tests exist to prove an AUTHORISED caller still receives a working
  # credential, so they print what they received. Two lines per run, and the run
  # output is the receipt.
  defp receipt(who, url, bytes) do
    IO.puts(
      "\n  [positive control] #{who}: signed=#{signed?(url)} bytes=#{bytes.status} " <>
        "(#{byte_size(bytes.resp_body)}B)\n    #{url}"
    )
  end

  describe "the signing switch is a principal test, not a query param" do
    test "ANONYMOUS appendRequestSecret must not mint a delivery signature for a token asset",
         %{conn: conn} do
      %{"id" => id} = asset_with_visibility(conn, "token")

      case anon_show(id, "?appendRequestSecret=true") do
        {:refused, status} ->
          assert status in [401, 403, 404],
                 "expected the anonymous read to be refused, got #{status}"

        {:ok, result} ->
          refute signed?(result["originalUrl"]),
                 "an anonymous caller was handed a SIGNED delivery URL: #{result["originalUrl"]}"
      end
    end

    # The escalation, end to end, in ONE test — because the two halves are only
    # a vulnerability together. Metadata disclosure alone is a lesser finding;
    # what makes this a `token`-tier bypass is that the URL handed over in
    # step one is the credential accepted in step two. The failure message
    # prints BOTH requests and BOTH statuses so a red run is the report.
    test "and the bytes stay refused end-to-end for whatever URL the anonymous caller can obtain",
         %{conn: conn} do
      %{"id" => id} = asset_with_visibility(conn, "token")

      meta_path = "/v1/media/#{@ds}/#{id}?appendRequestSecret=true"
      meta = get(build_conn(), meta_path)

      case meta.status do
        200 ->
          url = json_response(meta, 200)["result"]["originalUrl"]
          bytes = get(build_conn(), url)

          assert bytes.status == 403,
                 "ESCALATION anonymous->bytes:\n" <>
                   "  GET #{meta_path}  -> #{meta.status}, originalUrl = #{url}\n" <>
                   "  GET #{url}  -> #{bytes.status}, #{byte_size(bytes.resp_body)} bytes"

        status ->
          assert status in [401, 403, 404],
                 "expected the anonymous metadata read to be refused, got #{status}"
      end
    end

    test "POSITIVE CONTROL: a READ token still receives a working signed URL", %{conn: conn} do
      %{"id" => id} = asset_with_visibility(conn, "token")

      result =
        conn
        |> read_token()
        |> get(~p"/v1/media/#{@ds}/#{id}?appendRequestSecret=true")
        |> json_response(200)
        |> Map.fetch!("result")

      assert signed?(result["originalUrl"]),
             "an authorised read token lost its signature: #{result["originalUrl"]}"

      assert result["visibility"] == "token"

      # READ-only permission is the weakest credential that should still work.
      # `Access.authenticated?/1` is authentication, not authorization, so a
      # read token must clear it exactly as an admin token does — if this ever
      # reddens, the gate has quietly become a permission check.
      bytes = get(build_conn(), result["originalUrl"])
      assert bytes.status == 200
      receipt("read-only api token", result["originalUrl"], bytes)
    end

    test "POSITIVE CONTROL: a workspace-MEMBER account session receives a working signed URL on the scoped twin",
         %{conn: conn} do
      ws = create_workspace!("anonclamp-ws-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "anonclamp-p-#{System.unique_integer([:positive])}")

      email = "anonclamp-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
      {:ok, raw} = Accounts.create_user_session_token(user)

      session = fn c ->
        c
        |> Plug.Test.init_test_session(%{"user_session" => raw})
        |> put_req_header("x-requested-with", "bp-media-picker")
      end

      base = "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}"

      created =
        conn
        |> session.()
        |> post("#{base}/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["result"]["id"]

      on_exit(fn ->
        File.rm(Path.join(Media.upload_dir(), created["result"]["path"]))
        Media.Renditions.delete_for_file(id)
        Assets.delete_for_blob(id, @ds)
      end)

      conn
      |> session.()
      |> patch("#{base}/#{id}", %{"bp_visibility" => "token"})
      |> json_response(200)

      result =
        conn
        |> session.()
        |> get("#{base}/#{id}?appendRequestSecret=true")
        |> json_response(200)
        |> Map.fetch!("result")

      # PRECONDITION, and the thing that actually broke here first: on the
      # scoped twin the asset-doc lookup was resolving the `dataset` STRING in
      # the DEFAULT project, found nothing for a non-Default workspace, and
      # `Access.visibility(nil)` answered "public". The signature was missing
      # because the tier was missing. Assert the tier so a future regression
      # says WHICH half broke.
      assert result["visibility"] == "token",
             "the scoped twin lost the asset document — visibility came back " <>
               "#{inspect(result["visibility"])}, so every visibility gate on this " <>
               "route is asking about the wrong document"

      assert signed?(result["originalUrl"]),
             "a workspace member lost their signature: #{result["originalUrl"]}"

      # The member holds NO bearer token — only a `user_session`. This is the
      # principal `Access.authenticated?/1`'s account arm exists to admit, and
      # the reason the signing gate reuses that function instead of asking
      # `conn.assigns[:api_token] != nil` locally: the local spelling would
      # have refused this caller.
      #
      # THE SIGNATURE IS FETCHED AS THE MEMBER, NOT ANONYMOUSLY, and the
      # difference is the point. A scoped URL carries the /w/:ws/p/:proj prefix,
      # so its bytes are served by the SCOPED delivery route, where
      # `ResolveWorkspace` membership-gates BEFORE `Access.delivery_ok?/3` ever
      # sees the signature. An anonymous fetch of this URL is therefore refused
      # by the TENANCY wall, not by the signature — asserting 200 there would
      # have been asserting that a signature defeats tenancy, which is the
      # opposite of what this PR wants to be true. Both halves are pinned below
      # so a future reader cannot mistake one refusal for the other.
      bytes = session.(build_conn()) |> get(result["originalUrl"])
      assert bytes.status == 200
      receipt("workspace-member account session (no bearer)", result["originalUrl"], bytes)

      anon = get(build_conn(), result["originalUrl"])

      assert anon.status == 403,
             "a valid signature let an anonymous caller through the SCOPED delivery " <>
               "route's membership gate — signature must not defeat tenancy: #{anon.status}"
    end

    test "the SCOPED twin refuses an anonymous signature too", %{conn: conn} do
      ws = create_workspace!("anonclamp-sc-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "anonclamp-scp-#{System.unique_integer([:positive])}")
      %{"id" => id} = asset_with_visibility(conn, "token")

      path = "/w/#{ws.slug}/p/#{proj.slug}/v1/media/#{@ds}/#{id}?appendRequestSecret=true"
      resp = get(build_conn(), path)

      if resp.status == 200 do
        refute signed?(json_response(resp, 200)["result"]["originalUrl"]),
               "the scoped twin minted an anonymous signature"
      end
    end
  end

  describe "the metadata read is a principal test (task-27d5fdba100d2bc6 item 3)" do
    for vis <- ["token", "private"] do
      test "ANONYMOUS show must not disclose blob metadata for a #{vis} asset", %{conn: conn} do
        %{"id" => id, "filename" => filename} = asset_with_visibility(conn, unquote(vis))

        outcome = anon_show(id)

        # Bound first, then asserted on a boolean — `assert pattern = expr, msg`
        # discards the message, and this message is the whole finding: it names
        # the field that leaked.
        assert match?({:refused, _}, outcome),
               "an anonymous caller read #{unquote(vis)} blob metadata " <>
                 "(filename #{filename}): #{inspect(outcome, limit: 6)}"

        {:refused, status} = outcome
        assert status in [401, 403, 404]
      end

      test "POSITIVE CONTROL: a read token still reads #{vis} metadata", %{conn: conn} do
        %{"id" => id} = asset_with_visibility(conn, unquote(vis))

        result =
          conn
          |> read_token()
          |> get(~p"/v1/media/#{@ds}/#{id}")
          |> json_response(200)
          |> Map.fetch!("result")

        assert result["visibility"] == unquote(vis)
        assert is_binary(result["filename"])
      end
    end

    test "ANONYMOUS show still serves a PUBLIC asset unchanged", %{conn: conn} do
      %{"id" => id, "filename" => filename} = asset_with_visibility(conn, "public")

      assert {:ok, result} = anon_show(id)
      assert result["filename"] == filename
      assert result["visibility"] == "public"
    end

    test "ANONYMOUS relations must not disclose a token asset", %{conn: conn} do
      %{"id" => id} = asset_with_visibility(conn, "token")

      assert get(build_conn(), "/v1/media/#{@ds}/#{id}/relations").status in [401, 403, 404]
    end
  end

  describe "the listing doors clamp instead of refusing" do
    setup %{conn: conn} do
      public = asset_with_visibility(conn, "public")
      token = asset_with_visibility(conn, "token")
      private = asset_with_visibility(conn, "private")
      {:ok, public: public, token: token, private: private}
    end

    test "ANONYMOUS index omits token and private assets — and says so in `count`",
         %{public: public, token: token, private: private} do
      result =
        build_conn()
        |> get("/v1/media/#{@ds}?limit=500")
        |> json_response(200)
        |> Map.fetch!("result")

      listed = ids(result)

      assert public["id"] in listed, "the public asset vanished from the anonymous listing"
      refute token["id"] in listed, "a token asset leaked into the anonymous listing"
      refute private["id"] in listed, "a private asset leaked into the anonymous listing"

      assert result["count"] == length(listed),
             "`count` (#{result["count"]}) disagrees with the clamped rows (#{length(listed)}) — " <>
               "the clamp was applied to the page but not the total"
    end

    test "POSITIVE CONTROL: a read token still sees all three in index",
         %{conn: conn, public: public, token: token, private: private} do
      listed =
        conn
        |> read_token()
        |> get(~p"/v1/media/#{@ds}?limit=500")
        |> json_response(200)
        |> Map.fetch!("result")
        |> ids()

      for a <- [public, token, private] do
        assert a["id"] in listed, "an authorised caller lost asset #{a["id"]}"
      end
    end

    test "ANONYMOUS search omits token and private assets",
         %{public: public, token: token, private: private} do
      result =
        build_conn()
        |> get("/v1/media/#{@ds}/search?limit=500")
        |> json_response(200)
        |> Map.fetch!("result")

      listed = ids(result)

      assert public["id"] in listed
      refute token["id"] in listed, "a token asset leaked into the anonymous search"
      refute private["id"] in listed, "a private asset leaked into the anonymous search"
    end

    test "ANONYMOUS search FACETS must not census the tiers they cannot read" do
      result =
        build_conn()
        |> get("/v1/media/#{@ds}/search?facets=visibility&limit=1")
        |> json_response(200)
        |> Map.fetch!("result")

      values =
        (get_in(result, ["facets", "visibility"]) || [])
        |> Enum.map(& &1["value"])

      assert "token" not in values and "private" not in values,
             "the anonymous facet census enumerated non-public tiers: #{inspect(values)}"
    end

    test "ANONYMOUS search cannot filter its way to a private asset", %{private: private} do
      result =
        build_conn()
        |> get("/v1/media/#{@ds}/search?visibility=private&limit=500")
        |> json_response(200)
        |> Map.fetch!("result")

      refute private["id"] in ids(result),
             "visibility=private was accepted anonymously and returned the asset"
    end

    test "POSITIVE CONTROL: a read token CAN filter to private", %{conn: conn, private: private} do
      listed =
        conn
        |> read_token()
        |> get(~p"/v1/media/#{@ds}/search?visibility=private&limit=500")
        |> json_response(200)
        |> Map.fetch!("result")
        |> ids()

      assert private["id"] in listed
    end

    # The collection-assets door is a SEPARATE query builder
    # (`Collections.assets/3` -> `collection_search_opts/3` -> `Media.search_files/2`)
    # reached through a SEPARATE, forked `render_opts/4`. Fixing the
    # `/v1/media/:ds` family would not have touched it, and its take-list drops
    # any option not explicitly named — so a clamp that compiles here can still
    # enforce nothing. This test is what distinguishes those two outcomes.
    test "ANONYMOUS collection assets are clamped, and unsigned", %{
      conn: conn,
      public: public,
      token: token,
      private: private
    } do
      col_id = "anonclamp-col-#{System.unique_integer([:positive])}"

      {:ok, collection} =
        Content.upsert_document(
          "mediaCollection",
          %{
            "doc_id" => col_id,
            "title" => "Anon clamp",
            "content" => %{"kind" => "folder", "slug" => col_id}
          },
          @ds,
          source: :api
        )

      on_exit(fn -> Content.delete_document(col_id, "mediaCollection", @ds) end)

      for a <- [public, token, private] do
        conn
        |> admin()
        |> post(~p"/v1/media/#{@ds}/collections/#{collection.doc_id}/members", %{
          "assetId" => a["id"]
        })
        |> json_response(200)
      end

      path = "/v1/media/#{@ds}/collections/#{collection.doc_id}/assets"

      anon =
        build_conn()
        |> get("#{path}?limit=500&appendRequestSecret=true")
        |> json_response(200)
        |> Map.fetch!("result")

      listed = ids(anon)

      assert public["id"] in listed, "the public asset vanished from the anonymous collection"
      refute token["id"] in listed, "a token asset leaked through the collection door"
      refute private["id"] in listed, "a private asset leaked through the collection door"

      for hit <- anon["hits"] || [] do
        refute signed?(hit["originalUrl"]),
               "the collection door minted an anonymous signature: #{hit["originalUrl"]}"
      end

      authorised =
        conn
        |> read_token()
        |> get(~p"/v1/media/#{@ds}/collections/#{collection.doc_id}/assets?limit=500")
        |> json_response(200)
        |> Map.fetch!("result")
        |> ids()

      for a <- [public, token, private] do
        assert a["id"] in authorised,
               "an authorised caller lost asset #{a["id"]} from the collection"
      end
    end

    test "ANONYMOUS legacy /media index omits token and private assets",
         %{public: public, token: token, private: private} do
      body =
        build_conn()
        |> get("/media/?dataset=#{@ds}")
        |> json_response(200)

      listed = Enum.map(body["files"] || [], & &1["id"])

      assert public["id"] in listed
      refute token["id"] in listed, "a token asset leaked into the anonymous legacy listing"
      refute private["id"] in listed, "a private asset leaked into the anonymous legacy listing"
    end
  end
end
