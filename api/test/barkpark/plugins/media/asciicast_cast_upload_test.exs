defmodule Barkpark.Plugins.Media.AsciicastCastUploadTest do
  @moduledoc """
  pe-bl-asciicast-selfhost — Barkpark can HOST the `.cast` file.

  Half of "an asciicast plays with the CDN blocked" is the player (vendored,
  see `BarkparkWeb.Layouts.ReaderAsciicastSelfhostTest`); the other half is the
  recording, which until now could only be an off-site URL because nothing had
  ever put a `.cast` through media.

  THE FILING EXPECTED AN ALLOWLIST TO WIDEN. There is none to widen.
  `Barkpark.Media.validate_upload/3` reads `:allowed_mime_types` /
  `:allowed_extensions` from config, both `[]` in `config/config.exs:240-241`,
  and an empty list is documented as allow-all — media has a DENYLIST
  (`MediaFile.dangerous_mime?/1`: svg/html/xml/js), not an allowlist. So `.cast`
  needed no code change to be accepted, and this file is the proof of that
  claim rather than a test of new code. It is worth its bytes because the
  claim is load-bearing and non-obvious, and because three separate mechanisms
  could silently break it: a future allowlist, the MIME neutralizer, and the
  extension-preserving filename generator.

  What is pinned:

    * A `.cast` upload is ACCEPTED (no allowlist rejection).
    * Its `.cast` extension SURVIVES into the published `path`, so the URL a
      paper stores really ends in `.cast`.
    * Its recorded mime is NOT collapsed by `neutralize_dangerous_mime/1` —
      an asciicast is JSON-shaped text, and `Probe.sniff_bytes/1` must not
      mistake it for markup.
    * `GET /media/files/*path` returns 200 and the EXACT bytes. Byte identity
      is the assertion that matters: asciinema-player 3.x fetches the
      recording with `fetch()` and parses `response.text()`, ignoring the
      content-type entirely (independently observed in
      `tooling/grip/ledger/asciicast-local-proof-2026-07-31.json`: "the mime is
      NOT a blocker"), so what it needs from us is the bytes, not a label.
    * `Render.Util.safe_url/1` returns the media URL UNCHANGED — the root-
      relative form takes the `String.starts_with?(trimmed, "/")` arm — so the
      `asciicast` block can point at a Barkpark-hosted recording. This is the
      seam the row called out: the block "takes an external src URL only"
      because `safe_url` refuses `data:`, not because it refuses same-origin.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.PortableDoc.Render.Figures
  alias Barkpark.PortableDoc.Render.Util

  @dataset "production"

  # A minimal, REAL asciicast v2 file: a header object line, then two output
  # frames. Small enough to inline, complete enough that asciinema-player
  # renders text from it.
  @cast """
  {"version": 2, "width": 80, "height": 6, "timestamp": 1757462400, "env": {"SHELL": "/bin/zsh", "TERM": "xterm-256color"}}
  [0.1, "o", "barkpark self-hosted asciicast\\r\\n"]
  [0.6, "o", "no cdn required\\r\\n"]
  """

  defp upload_cast!(name \\ "demo.cast") do
    tmp = Path.join(System.tmp_dir!(), "bp-cast-#{:rand.uniform(1_000_000)}.cast")
    File.write!(tmp, @cast)

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: tmp, filename: name, content_type: "application/octet-stream"},
        @dataset
      )

    on_exit(fn -> File.rm(tmp) end)
    file
  end

  describe "a .cast upload" do
    test "is accepted — media's allowlist is empty, i.e. allow-all" do
      file = upload_cast!()
      assert file.id
      assert file.original_name == "demo.cast"
      assert file.size == byte_size(@cast)
    end

    test "keeps its .cast extension in the published path" do
      file = upload_cast!()

      assert String.ends_with?(file.path, ".cast"),
             "the stored path is what a paper links to; losing the extension would " <>
               "change what the URL claims to be"
    end

    test "is not collapsed by the dangerous-mime neutralizer" do
      file = upload_cast!()

      refute MediaFile.dangerous_mime?(file.mime_type),
             "an asciicast is JSON-shaped text; if the sniffer ever read it as " <>
               "markup the row would be rewritten to octet-stream as an XSS defence"
    end
  end

  describe "the serve edge" do
    test "returns the exact recording bytes", %{conn: conn} do
      file = upload_cast!()

      resp = get(conn, "/media/files/#{file.path}")

      assert resp.status == 200

      assert resp.resp_body == @cast,
             "the player fetch()es this and parses response.text() — byte identity " <>
               "is the whole contract"
    end
  end

  describe "the asciicast block accepts the media URL" do
    test "safe_url leaves a root-relative /media/files/... URL untouched" do
      file = upload_cast!()
      url = "/media/files/#{file.path}"

      assert Util.safe_url(url) == url,
             "safe_url refuses data: URIs, not same-origin paths"
    end

    test "the article-mode figure carries it as data-cast-src" do
      file = upload_cast!()
      url = "/media/files/#{file.path}"

      html = Figures.asciicast_html(url, "", "", nil, :article)

      assert html =~ ~s(data-cast-src="#{url}")
      refute html =~ ~s(data-cast-src="#"), "a rejected URL degrades to `#`"
    end
  end
end
