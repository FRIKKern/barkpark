defmodule Barkpark.Plugins.Media.AsciicastCastUploadTest do
  @moduledoc """
  pe-bl-asciicast-selfhost — Barkpark can HOST the `.cast` file.

  Half of "an asciicast plays with the CDN blocked" is the player (vendored;
  see `BarkparkWeb.Layouts.ReaderAsciicastSelfhostTest`). The other half is the
  recording, which until now was always somebody else's URL because nothing had
  ever put a `.cast` through the media door.

  THE FILING EXPECTED AN ALLOWLIST TO WIDEN. There is none to widen.
  `Barkpark.Media.upload/3` calls `validate_upload/3`, which reads
  `:allowed_mime_types` / `:allowed_extensions` from app config — both `[]` in
  `config/config.exs:240-241`, and an empty list is documented there as
  allow-all. Media enforces a DENYLIST (`MediaFile.dangerous_mime?/1`:
  svg/html/xml/js), never an allowlist. `.cast` therefore needed no code change
  to be accepted, and this file is the PROOF of that claim rather than a test
  of new code. It earns its bytes because the claim is load-bearing and
  non-obvious, and because three independent mechanisms could silently falsify
  it later: a future allowlist, the dangerous-mime neutralizer, and the
  extension-preserving filename generator.

  It drives the REAL HTTP door — `POST /media/upload` then
  `GET /media/files/*path` — rather than `Media.upload/3` in-process, because
  the published URL is what a paper stores and it is the controller, not the
  context, that mints it.

  Pinned here:

    * A `.cast` upload is ACCEPTED: 201, with a `/media/files/...` URL.
    * The `.cast` extension SURVIVES into that URL.
    * The recorded mime is NOT collapsed by the dangerous-mime neutralizer —
      an asciicast is JSON-shaped text and `Probe.sniff_bytes/1` must not read
      it as markup.
    * `GET` of that URL returns 200 and the EXACT bytes. Byte identity is the
      whole contract: asciinema-player 3.x fetches the recording with
      `fetch()` and parses `response.text()`, never inspecting the
      content-type (independently observed in
      `tooling/grip/ledger/asciicast-local-proof-2026-07-31.json` — "the mime
      is NOT a blocker"). What the player needs from us is bytes, not a label.
    * `Render.Util.safe_url/1` returns that URL UNCHANGED — a root-relative
      path takes the `String.starts_with?(trimmed, "/")` arm — so an
      `asciicast` block can point at a Barkpark-hosted recording. That is the
      seam the row named: the block took "an external src URL only" because
      `safe_url` refuses `data:` URIs, not because it refuses same-origin.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.PortableDoc.Render.Figures
  alias Barkpark.PortableDoc.Render.Util

  # A minimal but REAL asciicast v2 file: the header object line, then two
  # output frames. Small enough to inline; complete enough that the player
  # paints text from it.
  @cast """
  {"version": 2, "width": 80, "height": 6, "timestamp": 1757462400, "env": {"SHELL": "/bin/zsh", "TERM": "xterm-256color"}}
  [0.1, "o", "barkpark self-hosted asciicast\\r\\n"]
  [0.6, "o", "no cdn required\\r\\n"]
  """

  setup do
    Barkpark.Auth.create_token(
      "barkpark-cast-token",
      "dev",
      "asciicast-selfhost",
      ["read", "write", "admin"]
    )

    :ok
  end

  defp cast_upload do
    tmp = Path.join(System.tmp_dir!(), "barkpark-cast-#{:rand.uniform(1_000_000)}.cast")
    File.write!(tmp, @cast)
    %Plug.Upload{path: tmp, filename: "demo.cast", content_type: "application/octet-stream"}
  end

  defp upload_cast!(conn) do
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-cast-token")
      |> post(~p"/media/upload", %{"file" => cast_upload()})
      |> json_response(201)

    "/media/files/" <> relative = body["url"]
    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), relative)) end)

    body
  end

  describe "POST /media/upload with a .cast" do
    test "is accepted — media's allowlist is empty, i.e. allow-all", %{conn: conn} do
      body = upload_cast!(conn)

      assert is_binary(body["id"])
      assert body["size"] == byte_size(@cast)
      assert String.starts_with?(body["url"], "/media/files/")
    end

    test "keeps the .cast extension in the published URL", %{conn: conn} do
      body = upload_cast!(conn)

      assert String.ends_with?(body["url"], ".cast"),
             "the URL is what a paper stores; losing the extension would change " <>
               "what the link claims to be"
    end

    test "the recorded mime is not collapsed by the dangerous-mime neutralizer",
         %{conn: conn} do
      body = upload_cast!(conn)

      refute MediaFile.dangerous_mime?(body["mimeType"]),
             "an asciicast is JSON-shaped text; were the sniffer ever to read it " <>
               "as markup the row would be rewritten to octet-stream as an XSS defence"
    end
  end

  describe "GET the hosted recording" do
    test "returns 200 and the exact recording bytes", %{conn: conn} do
      body = upload_cast!(conn)

      resp = get(conn, body["url"])

      assert resp.status == 200

      assert resp.resp_body == @cast,
             "the player fetch()es this and parses response.text() — byte identity " <>
               "is the whole contract"
    end
  end

  describe "the asciicast block accepts the media URL" do
    test "safe_url leaves the /media/files/... URL untouched", %{conn: conn} do
      url = upload_cast!(conn)["url"]

      assert Util.safe_url(url) == url,
             "safe_url refuses data: URIs, not same-origin paths"
    end

    test "the article-mode figure carries it as data-cast-src", %{conn: conn} do
      url = upload_cast!(conn)["url"]

      html = Figures.asciicast_html(url, "", "", nil, :article)

      assert html =~ ~s(data-cast-src="#{url}")
      refute html =~ ~s(data-cast-src="#"), "a rejected URL degrades to `#`"
    end
  end
end
