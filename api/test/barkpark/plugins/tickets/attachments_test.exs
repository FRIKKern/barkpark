defmodule Barkpark.Plugins.Tickets.AttachmentsTest do
  @moduledoc """
  Pins the outsider-media trust boundary for ticket attachments.

  Two layers:

    * The PURE validation core (`sniff/1`, `allow?/1`, `validate/2`,
      `validate_count/1`) — magic-byte MIME, allowlist, size + count caps, and a
      typed error for every rejection. This is the security-critical surface: a
      leaked ticket key must never be able to smuggle an executable past the
      allowlist by lying about Content-Type or extension.
    * The controller (`BarkparkWeb.TicketsAttachmentsController`) — ownership
      scoping (foreign ticket / foreign attachment → 404, never 403), the honest
      status codes for each rejection, and the round-trip happy path through the
      Media storage internals.

  Controller actions are exercised by calling them directly with a hand-built
  conn (the `RequireTicketKey` plug is sibling-owned and absent in this
  worktree — the charter says to assign the key map directly).
  """
  use Barkpark.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Tickets.Attachments
  alias Barkpark.Repo
  alias BarkparkWeb.TicketsAttachmentsController, as: Controller

  @dataset "production"

  # ── Real magic-byte fixtures (inline binaries; no fixture files) ───────────
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00>>
  @gif <<"GIF89a", 0x01, 0x00, 0x01, 0x00, 0x00>>
  @webp <<"RIFF", 0x1A, 0x00, 0x00, 0x00, "WEBP", "VP8 ">>
  @pdf <<"%PDF-1.4\n1 0 obj\n<< >>\nendobj\n">>
  @txt <<"hello world\nthis is a plain text file\n">>
  @log <<"2026-07-03T12:00:00Z INFO boot ok\n2026-07-03T12:00:01Z WARN slow\n">>
  @zip <<0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00>>

  # Non-allowlisted but HONESTLY declared (a real gzip called what it is).
  @gzip <<0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00>>
  # An ELF executable — the exact byte payload a "spoofed .png" would carry.
  @elf <<0x7F, "ELF", 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>

  setup do
    # Same substrate the Media asset tests use: registering the plugin +
    # installing its schema makes `Media.upload/3` and the `mediaAsset`
    # companion doc work under the SQL sandbox.
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} =
      Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})

    Barkpark.Plugins.Media.Codelists.seed_all()
    :ok
  end

  # ═══════════════════════════════ pure core ════════════════════════════════

  describe "sniff/1 — server-derived MIME from magic bytes" do
    test "recognizes every allowlisted binary type" do
      assert Attachments.sniff(@png) == "image/png"
      assert Attachments.sniff(@jpeg) == "image/jpeg"
      assert Attachments.sniff(@gif) == "image/gif"
      assert Attachments.sniff(<<"GIF87a", 0, 0>>) == "image/gif"
      assert Attachments.sniff(@webp) == "image/webp"
      assert Attachments.sniff(@pdf) == "application/pdf"
      assert Attachments.sniff(@zip) == "application/zip"
    end

    test "derives text/plain for printable text (covers .txt and .log)" do
      assert Attachments.sniff(@txt) == "text/plain"
      assert Attachments.sniff(@log) == "text/plain"
    end

    test "derives text/plain for UTF-8 text (non-ASCII logs are still text)" do
      norsk = String.duplicate("2026-07-03 WARN Blåbærsyltetøy: øl på lager\n", 4)
      assert Attachments.sniff(norsk) == "text/plain"
      # Mostly-multibyte text whose sampling window cuts a character in half is
      # still text — the boundary trim must not flip it to binary.
      assert Attachments.sniff(String.duplicate("aæ", 600)) == "text/plain"
    end

    test "returns nil for unknown / binary content, ignoring any extension" do
      assert Attachments.sniff(@gzip) == nil
      assert Attachments.sniff(@elf) == nil
      assert Attachments.sniff(<<>>) == nil
      # High-byte junk that is NOT valid UTF-8 stays binary.
      assert Attachments.sniff(:binary.copy(<<0xC3, 0x28>>, 100)) == nil
      # UTF-16 ("t\0e\0x\0t\0") carries NULs — the hard binary tell.
      assert Attachments.sniff(<<"t", 0, "e", 0, "x", 0, "t", 0>>) == nil
    end
  end

  describe "allow?/1" do
    test "accepts exactly the charter allowlist" do
      for mime <-
            ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain application/zip) do
        assert Attachments.allow?(mime)
      end
    end

    test "rejects everything else" do
      refute Attachments.allow?("application/gzip")
      refute Attachments.allow?("image/svg+xml")
      refute Attachments.allow?("application/x-msdownload")
      refute Attachments.allow?(nil)
    end
  end

  describe "validate/2 — happy path per allowlisted type" do
    test "accepts each type and returns the SERVER-derived MIME" do
      assert {:ok, "image/png"} = Attachments.validate(@png, filename: "a.png")
      assert {:ok, "image/jpeg"} = Attachments.validate(@jpeg, filename: "a.jpg")
      assert {:ok, "image/gif"} = Attachments.validate(@gif, filename: "a.gif")
      assert {:ok, "image/webp"} = Attachments.validate(@webp, filename: "a.webp")
      assert {:ok, "application/pdf"} = Attachments.validate(@pdf, filename: "a.pdf")
      assert {:ok, "text/plain"} = Attachments.validate(@txt, filename: "notes.txt")
      assert {:ok, "text/plain"} = Attachments.validate(@log, filename: "server.log")
      assert {:ok, "application/zip"} = Attachments.validate(@zip, filename: "a.zip")
    end
  end

  describe "validate/2 — rejections" do
    test "honestly-declared disallowed type → :mime_not_allowed" do
      assert {:error, :mime_not_allowed} =
               Attachments.validate(@gzip,
                 filename: "backup.gz",
                 content_type: "application/gzip"
               )
    end

    test "executable bytes wearing a .png name + image/png header → :mime_spoofed" do
      assert {:error, :mime_spoofed} =
               Attachments.validate(@elf,
                 filename: "cute-cat.png",
                 content_type: "image/png"
               )
    end

    test "a lie via the extension alone (no Content-Type) is still :mime_spoofed" do
      assert {:error, :mime_spoofed} = Attachments.validate(@elf, filename: "cute-cat.png")
    end

    test "over the 10 MB cap → :too_large (before any sniff)" do
      oversize = :binary.copy(<<0>>, Attachments.max_bytes() + 1)
      assert {:error, :too_large} = Attachments.validate(oversize, filename: "big.png")
    end

    test "exactly at the cap is allowed by the size gate" do
      # A png header padded to exactly the cap still passes the size check.
      pad = :binary.copy(<<0>>, Attachments.max_bytes() - byte_size(@png))
      assert {:ok, "image/png"} = Attachments.validate(@png <> pad)
    end
  end

  describe "validate_count/1" do
    test "allows up to the cap, refuses the one past it" do
      assert :ok = Attachments.validate_count(0)
      assert :ok = Attachments.validate_count(Attachments.max_attachments() - 1)

      assert {:error, :too_many_attachments} =
               Attachments.validate_count(Attachments.max_attachments())
    end
  end

  # ═══════════════════════════════ controller ═══════════════════════════════

  describe "create/2 — upload boundary" do
    test "owning key uploads an allowed file → 201 with an asset ref" do
      ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")

      conn =
        Controller.create(conn, %{
          "id" => ticket,
          "file" => upload(@pdf, "doc.pdf", "application/pdf")
        })

      assert conn.status == 201
      body = json_response(conn, 201)
      assert %{"attachment" => ref} = body
      assert is_binary(ref["asset_id"])
      assert ref["content_type"] == "application/pdf"
      assert ref["size"] == byte_size(@pdf)
    end

    test "foreign ticket → 404 (never 403, never leaks existence)" do
      ticket_a = insert_ticket!("key-A")
      conn = submitter_conn("key-B")

      conn =
        Controller.create(conn, %{
          "id" => ticket_a,
          "file" => upload(@pdf, "doc.pdf", "application/pdf")
        })

      assert conn.status == 404
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "missing key → 401" do
      ticket = insert_ticket!("key-A")
      conn = build_conn()

      conn =
        Controller.create(conn, %{
          "id" => ticket,
          "file" => upload(@pdf, "doc.pdf", "application/pdf")
        })

      assert conn.status == 401
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "blocked MIME → 422 :mime_not_allowed" do
      ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")

      conn =
        Controller.create(conn, %{
          "id" => ticket,
          "file" => upload(@gzip, "backup.gz", "application/gzip")
        })

      assert conn.status == 422
      env = json_response(conn, 422)["error"]
      assert env["code"] == "validation_failed"
      assert env["details"]["reason"] == "mime_not_allowed"
    end

    test "spoofed executable named .png → 422 :mime_spoofed" do
      ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")

      conn =
        Controller.create(conn, %{"id" => ticket, "file" => upload(@elf, "cute.png", "image/png")})

      assert conn.status == 422
      env = json_response(conn, 422)["error"]
      assert env["code"] == "validation_failed"
      assert env["details"]["reason"] == "mime_spoofed"
    end

    test "oversize file → 413" do
      ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")
      big = @png <> :binary.copy(<<0>>, Attachments.max_bytes() + 1)

      conn =
        Controller.create(conn, %{"id" => ticket, "file" => upload(big, "big.png", "image/png")})

      assert conn.status == 413
      assert json_response(conn, 413)["error"]["code"] == "payload_too_large"
    end

    test "the 11th attachment → 422 :too_many_attachments" do
      ticket = insert_ticket!("key-A")
      for _ <- 1..Attachments.max_attachments(), do: seed_attachment_doc!(ticket)
      conn = submitter_conn("key-A")

      conn =
        Controller.create(conn, %{
          "id" => ticket,
          "file" => upload(@pdf, "doc.pdf", "application/pdf")
        })

      assert conn.status == 422
      env = json_response(conn, 422)["error"]
      assert env["code"] == "validation_failed"
      assert env["details"]["reason"] == "too_many_attachments"
    end

    test "authenticated but no file part → 400" do
      ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")

      conn = Controller.create(conn, %{"id" => ticket})

      assert conn.status == 400
      assert json_response(conn, 400)["error"]["code"] == "malformed"
    end
  end

  describe "show/2 + show_operator/2 — retrieval boundary" do
    setup do
      ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")

      created =
        Controller.create(conn, %{
          "id" => ticket,
          "file" => upload(@pdf, "doc.pdf", "application/pdf")
        })

      asset_id = json_response(created, 201)["attachment"]["asset_id"]
      %{ticket: ticket, asset_id: asset_id}
    end

    test "owning key streams the exact bytes back → 200", %{ticket: ticket, asset_id: asset_id} do
      conn = submitter_conn("key-A")
      conn = Controller.show(conn, %{"id" => ticket, "asset_id" => asset_id})

      assert conn.status == 200
      assert response(conn, 200) == @pdf
    end

    test "streams with the server-derived MIME, nosniff and an inline disposition",
         %{ticket: ticket, asset_id: asset_id} do
      conn = submitter_conn("key-A")
      conn = Controller.show(conn, %{"id" => ticket, "asset_id" => asset_id})

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="doc.pdf")]
    end

    test "foreign key → 404", %{ticket: ticket, asset_id: asset_id} do
      _other = insert_ticket!("key-B")
      conn = submitter_conn("key-B")
      conn = Controller.show(conn, %{"id" => ticket, "asset_id" => asset_id})

      assert conn.status == 404
    end

    test "foreign ATTACHMENT (asset from another of my own tickets) → 404",
         %{asset_id: asset_id} do
      # key-A owns this OTHER ticket, but the asset belongs to the first ticket.
      other_ticket = insert_ticket!("key-A")
      conn = submitter_conn("key-A")
      conn = Controller.show(conn, %{"id" => other_ticket, "asset_id" => asset_id})

      assert conn.status == 404
    end

    test "operator token streams it back → 200", %{ticket: ticket, asset_id: asset_id} do
      conn = build_conn() |> assign(:api_token, %{id: "operator-token"})
      conn = Controller.show_operator(conn, %{"id" => ticket, "asset_id" => asset_id})

      assert conn.status == 200
      assert response(conn, 200) == @pdf
    end

    test "operator on a non-existent ticket → 404", %{asset_id: asset_id} do
      conn = build_conn() |> assign(:api_token, %{id: "operator-token"})
      conn = Controller.show_operator(conn, %{"id" => "no-such-ticket", "asset_id" => asset_id})

      assert conn.status == 404
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp submitter_conn(key_id) do
    build_conn() |> assign(:ticket_key, %{id: key_id, dataset: @dataset})
  end

  defp insert_ticket!(key_id) do
    doc_id = "ticket-" <> Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "ticket",
      dataset: @dataset,
      status: "open",
      rev: "1",
      content: %{"key_id" => key_id, "status" => "open", "messages" => []}
    })

    doc_id
  end

  # Seed a bare mediaAsset doc stamped to a ticket so count_for_ticket/3 sees it
  # without a full upload round-trip.
  defp seed_attachment_doc!(ticket_id) do
    doc_id = "drafts.asset-" <> Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "mediaAsset",
      dataset: @dataset,
      status: "draft",
      rev: "1",
      content: %{"bp_ticket_id" => ticket_id, "mediaFileId" => doc_id}
    })
  end

  defp upload(bytes, filename, content_type) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bptk-test-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: filename, content_type: content_type}
  end
end
