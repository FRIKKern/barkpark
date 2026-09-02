defmodule BarkparkWeb.ChatAttachmentControllerTest do
  @moduledoc """
  Chat-owned attachment transport (`ct-bl-chat-attachments`, charter D16/D6).

  The named failure mode this file exists to stop: attachments riding the media
  plugin. `GET /media/files/*` is any-token-public by design, so a chat
  attachment served through it would be readable by a token class that can not
  reach the conversation — a confidentiality regression dressed as a parity
  feature. Every test here pins one leg of the replacement boundary:

    * the round trip works through the chat-owned routes (upload → read);
    * the id on the wire is opaque and content-addressed, and no store path,
      bearer token, or raw byte ever rides the transcript;
    * three token classes are refused: a plain data-plane token (403 at the
      pipeline), another workspace's Connector (404, the not-found oracle), and
      every media route (which never serves these bytes, not even to a global
      admin).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  # A real 1x1 PNG — the store SNIFFS the media type from these magic bytes, so
  # a fixture that is not genuinely a PNG would be refused (which is itself
  # pinned below).
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  # A real (tiny) GIF87a header + trailer — a second accepted type, so the
  # allowlist test is not a single-type tautology.
  @gif "GIF87a" <> <<1, 0, 1, 0, 0x80, 0, 0>> <> <<0, 0, 0, 255, 255, 255, 0x3B>>

  setup do
    prev = Application.get_env(:barkpark, StudioChat)

    # A per-run attachments root: the shared test tmp dir is written by every
    # agent on this box, and a test that asserts "exactly one file on disk"
    # must not be reading a peer's leftovers.
    dir =
      Path.join(
        System.tmp_dir!(),
        "bp_chat_attachment_ctl_test_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:barkpark, StudioChat, prev),
        else: Application.delete_env(:barkpark, StudioChat)
    end)

    admin = "chat-att-admin-#{System.unique_integer([:positive])}"
    reader = "chat-att-reader-#{System.unique_integer([:positive])}"
    writer = "chat-att-writer-#{System.unique_integer([:positive])}"

    {:ok, _} = Auth.create_token(admin, "att-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "att-reader", @dataset, ["read"])
    {:ok, _} = Auth.create_token(writer, "att-writer", @dataset, ["read", "write"])

    {:ok, session} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"})

    %{admin: admin, reader: reader, writer: writer, sid: session.id, dir: dir}
  end

  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp json_conn(raw), do: as(build_conn(), raw)

  defp upload(raw, sid, bytes) do
    json_conn(raw)
    |> post("/v1/chat/sessions/#{sid}/attachments", Jason.encode!(%{data: Base.encode64(bytes)}))
  end

  # ── criterion 0: the round trip ────────────────────────────────────────────

  describe "upload/read round trip (admin-gated, content-addressed, opaque id)" do
    test "an admin uploads bytes and reads the SAME bytes back through the chat-owned route",
         %{admin: admin, sid: sid} do
      created = upload(admin, sid, @png) |> json_response(201)
      att = created["attachment"]

      assert att["media_type"] == "image/png"
      assert att["byte_size"] == byte_size(@png)

      # Opaque id: a bare content address — no directory, no session id, no
      # filename, no extension, no token.
      assert att["id"] =~ ~r/\A[0-9a-f]{64}\z/,
             "attachment id must be an opaque content address; got #{inspect(att["id"])}"

      assert att["url"] == "/v1/chat/sessions/#{sid}/attachments/#{att["id"]}"

      # THE ROUND TRIP: read it back and compare bytes, not metadata.
      read = json_conn(admin) |> get(att["url"]) |> json_response(200)

      assert Base.decode64!(read["attachment"]["data"]) == @png,
             "the read route must return the exact bytes that were uploaded"

      assert read["attachment"]["id"] == att["id"]
      assert read["attachment"]["media_type"] == "image/png"
      assert read["attachment"]["byte_size"] == byte_size(@png)
    end

    test "storage is content-addressed: identical bytes de-dupe to one id and one file",
         %{admin: admin, sid: sid, dir: dir} do
      first = upload(admin, sid, @png) |> json_response(201)
      second = upload(admin, sid, @png) |> json_response(201)

      assert first["attachment"]["id"] == second["attachment"]["id"],
             "the same bytes must yield the same content address"

      assert File.ls!(Path.join(dir, sid)) == [first["attachment"]["id"]],
             "content-addressed storage must keep exactly one file for identical bytes"

      # Different bytes ⇒ a different id and a second file.
      other = upload(admin, sid, @gif) |> json_response(201)
      assert other["attachment"]["media_type"] == "image/gif"
      refute other["attachment"]["id"] == first["attachment"]["id"]
      assert length(File.ls!(Path.join(dir, sid))) == 2
    end

    test "the upload response carries no store path, no token, and no bytes",
         %{admin: admin, sid: sid} do
      body = upload(admin, sid, @png) |> response(201)

      refute body =~ "path",
             "the wire reference must never carry the store path"

      refute body =~ admin, "a bearer token must never ride the response"
      refute body =~ Base.encode64(@png), "the upload ack must not echo the bytes"
    end

    test "a bare 404 for an unknown or malformed attachment id (never a store probe)",
         %{admin: admin, sid: sid} do
      unknown = String.duplicate("a", 64)

      assert json_conn(admin)
             |> get("/v1/chat/sessions/#{sid}/attachments/#{unknown}")
             |> json_response(404)

      # A traversal-shaped id is rejected on shape, before the store is touched.
      # Shape-rejected ids: wrong charset, wrong case, wrong length, and a
      # sidecar-looking suffix — each must 404 without reaching the store.
      for bad <- ["not-hex", String.duplicate("A", 64), "abc123", "#{unknown}.meta"] do
        assert json_conn(admin)
               |> get("/v1/chat/sessions/#{sid}/attachments/#{bad}")
               |> json_response(404),
               "malformed attachment id #{inspect(bad)} must 404"
      end
    end

    test "strict body validation refuses a bad upload BEFORE anything is stored",
         %{admin: admin, sid: sid, dir: dir} do
      bad_bodies = [
        {%{}, "missing data"},
        {%{data: 42}, "non-string data"},
        {%{data: "!!!not base64!!!"}, "invalid base64"},
        {%{data: Base.encode64("plain text, not an image")}, "not an accepted image"},
        {%{data: Base.encode64(@png), media_type: "image/png"}, "unknown key"},
        {%{data: Base.encode64("<svg xmlns='http://www.w3.org/2000/svg'/>")}, "svg is refused"}
      ]

      for {body, why} <- bad_bodies do
        conn =
          json_conn(admin) |> post("/v1/chat/sessions/#{sid}/attachments", Jason.encode!(body))

        assert json_response(conn, 400)["error"]["code"] == "invalid_request",
               "#{why} must be a canonical 400"
      end

      # An over-cap payload is refused too (built just past the ceiling, still a
      # real PNG prefix so the refusal is the SIZE leg, not the sniff leg).
      oversize = @png <> :binary.copy(<<0>>, Attachments.max_bytes())

      assert json_conn(admin)
             |> post(
               "/v1/chat/sessions/#{sid}/attachments",
               Jason.encode!(%{data: Base.encode64(oversize)})
             )
             |> json_response(400)

      refute File.dir?(Path.join(dir, sid)),
             "a refused upload must not create the session's store directory"
    end
  end

  # ── criterion 1: the three negative boundaries ─────────────────────────────

  describe "a plain data-plane token cannot retrieve chat attachment bytes" do
    test "read/write tokens are 403'd at the pipeline on BOTH attachment routes",
         %{admin: admin, reader: reader, writer: writer, sid: sid} do
      att = upload(admin, sid, @png) |> json_response(201) |> Map.fetch!("attachment")

      for {label, token} <- [{"read-only", reader}, {"read+write", writer}] do
        up =
          json_conn(token)
          |> post(
            "/v1/chat/sessions/#{sid}/attachments",
            Jason.encode!(%{data: Base.encode64(@png)})
          )

        assert json_response(up, 403),
               "a #{label} data-plane token must not upload chat attachments"

        down = json_conn(token) |> get(att["url"])
        assert json_response(down, 403), "a #{label} data-plane token must not read chat bytes"

        refute down.resp_body =~ Base.encode64(@png),
               "the refusal must not leak the bytes"
      end

      # An anonymous caller never gets past RequireToken either.
      assert build_conn() |> get(att["url"]) |> json_response(401)
    end
  end

  describe "a token from another workspace cannot retrieve chat attachment bytes" do
    setup do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      conn_a = "att-conn-a-#{System.unique_integer([:positive])}"
      conn_b = "att-conn-b-#{System.unique_integer([:positive])}"

      {:ok, _} = Auth.create_token(conn_a, "att-a", @dataset, ["read", "chat"], ws_a.id)
      {:ok, _} = Auth.create_token(conn_b, "att-b", @dataset, ["read", "chat"], ws_b.id)

      {:ok, session} =
        StudioChat.create_session(
          %{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"},
          {:workspace, ws_a.id}
        )

      %{conn_a: conn_a, conn_b: conn_b, ws_b: ws_b, ws_sid: session.id}
    end

    test "ws-B joins the not-found oracle on ws-A's attachments (never a distinct 403)",
         %{conn_a: conn_a, conn_b: conn_b, ws_b: ws_b, ws_sid: sid} do
      # POSITIVE control first: the OWNER round-trips, so the 404s below are
      # isolation and not a dead token or a broken route.
      att = upload(conn_a, sid, @png) |> json_response(201) |> Map.fetch!("attachment")

      owner_read = json_conn(conn_a) |> get(att["url"]) |> json_response(200)
      assert Base.decode64!(owner_read["attachment"]["data"]) == @png

      # ws-B holds a VALID chat token — it passes RequireChatAccess — and is
      # still confined to its own tenant on both routes.
      up =
        json_conn(conn_b)
        |> post(
          "/v1/chat/sessions/#{sid}/attachments",
          Jason.encode!(%{data: Base.encode64(@png)})
        )

      assert json_response(up, 404)["error"]["code"] == "not_found",
             "a cross-tenant upload must join the not-found oracle, not a distinct 403"

      down = json_conn(conn_b) |> get(att["url"])

      assert json_response(down, 404)["error"]["code"] == "not_found",
             "a cross-tenant read must join the not-found oracle, not a distinct 403"

      refute down.resp_body =~ Base.encode64(@png),
             "the cross-tenant refusal must not leak the bytes"

      # And ws-B is not simply broken: it round-trips on its OWN session.
      {:ok, own} =
        StudioChat.create_session(
          %{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"},
          {:workspace, ws_b.id}
        )

      own_att = upload(conn_b, own.id, @gif) |> json_response(201) |> Map.fetch!("attachment")
      assert json_conn(conn_b) |> get(own_att["url"]) |> json_response(200)
    end
  end

  describe "no media route retrieves chat attachment bytes" do
    test "every media read route fails on the chat store's own path — even for a global admin",
         %{admin: admin, sid: sid} do
      att = upload(admin, sid, @png) |> json_response(201) |> Map.fetch!("attachment")
      id = att["id"]
      encoded = Base.encode64(@png)

      # The exact spellings a caller would reach for if attachments HAD ridden
      # the media plugin: the store's relative pointer path, its leaf, and the
      # opaque id, across every mounted media read route.
      media_calls =
        for path <- ["#{sid}/#{id}", id, "chat/#{sid}/#{id}"] do
          "/media/files/#{path}"
        end ++
          [
            "/media/#{id}/meta",
            "/media/renditions/#{id}/thumb",
            "/media?limit=50"
          ]

      for url <- media_calls do
        conn = json_conn(admin) |> get(url)

        refute conn.status == 200 and conn.resp_body == @png,
               "#{url} served the chat attachment bytes verbatim"

        refute conn.resp_body =~ encoded,
               "#{url} leaked the chat attachment bytes (base64)"

        refute conn.resp_body =~ id,
               "#{url} disclosed the chat attachment id — media must not know these files exist"
      end

      # The chat-owned route still serves them, so the assertions above are a
      # boundary and not a broken fixture.
      assert json_conn(admin) |> get(att["url"]) |> json_response(200)
    end
  end

  # ── criterion 2: ONE reference shape in the transcript ─────────────────────

  describe "the transcript carries the reference shape only" do
    test "a user row projects {id, media_type, byte_size, url} and NO store path",
         %{admin: admin, sid: sid} do
      att = upload(admin, sid, @png) |> json_response(201) |> Map.fetch!("attachment")

      # Persist a user row the way the Studio composer does: the jsonb pointer
      # (which DOES carry the store path) never leaves the DB.
      {:ok, pointer} = Attachments.put(sid, @png)

      {:ok, _} =
        StudioChat.append_message(sid, %{
          role: "user",
          source_markdown: "look at this",
          metadata: %{"attachments" => [Attachments.pointer_json(pointer)]}
        })

      conn = json_conn(admin) |> get("/v1/chat/sessions/#{sid}")
      body = json_response(conn, 200)
      [message] = body["messages"]

      assert message["attachments"] == [
               %{
                 "id" => att["id"],
                 "media_type" => "image/png",
                 "byte_size" => byte_size(@png),
                 "url" => "/v1/chat/sessions/#{sid}/attachments/#{att["id"]}"
               }
             ]

      refute Map.has_key?(message["metadata"], "attachments"),
             "the raw pointer (which carries the store path) must be lifted out of metadata"

      raw = conn.resp_body

      refute raw =~ pointer.path,
             "the store path #{inspect(pointer.path)} reached the transcript"

      refute raw =~ "\"path\"", "the transcript must carry no path key"
      refute raw =~ admin, "the transcript must carry no bearer token"
      refute raw =~ Base.encode64(@png), "the transcript must carry no raw bytes"

      # The reference is ACTIONABLE: the url on the transcript resolves.
      read = json_conn(admin) |> get(hd(message["attachments"])["url"]) |> json_response(200)
      assert Base.decode64!(read["attachment"]["data"]) == @png
    end

    test "an attachment-free row is byte-identical to before (no empty key)",
         %{admin: admin, sid: sid} do
      {:ok, _} =
        StudioChat.append_message(sid, %{
          role: "user",
          source_markdown: "no images here",
          metadata: %{"origin" => "api"}
        })

      [message] =
        json_conn(admin)
        |> get("/v1/chat/sessions/#{sid}")
        |> json_response(200)
        |> Map.fetch!("messages")

      refute Map.has_key?(message, "attachments"),
             "a row with no attachments must not gain an empty attachments key"

      assert message["metadata"] == %{"origin" => "api"}
    end
  end
end
