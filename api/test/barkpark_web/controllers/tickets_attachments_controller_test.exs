defmodule BarkparkWeb.TicketsAttachmentsControllerTest do
  @moduledoc """
  Conn-level coverage for the SUBMITTER half of the ticket-attachment surface
  (acpc-bl-missing-conn-test-homes), driven through the REAL router and the real
  `:ticket_key` pipeline.

      POST /v1/tickets/:id/attachments             → :create
      GET  /v1/tickets/:id/attachments/:asset_id   → :show

  ## Why this file exists

  The OPERATOR read (`GET /v1/tickets/inbox/:id/attachments/:asset_id`) gained
  conn coverage in `tickets_attachments_session_pipeline_test.exs` (#14750). The
  two SUBMITTER routes had none: the only tests that named them were
  `ticket_rate_limit_test.exs` (which asserts `.halted` on a hand-built conn and
  never reaches the controller) and `cli_test.exs` (which asserts the route
  STRINGS appear in the CLI manifest). The controller's own ownership gate —
  `owned_ticket/2`'s `content["key_id"] == key.id` compare — and its malformed
  `:asset_id` arm were therefore proven only one layer down, at
  `media_test.exs`'s `get_file/2` guard. A change that stopped delegating to
  `Media.get_file/2`, or that dropped the key_id compare, would have regressed
  invisibly at the HTTP boundary.

  ## What is asserted, and how it stays non-vacuous

  Every test dispatches a real request through `BarkparkWeb.Endpoint`, so the
  `:ticket_key` pipeline (`RequireTicketKey` + `TicketRateLimit`) runs for real.
  The legitimate submitter is the POSITIVE CONTROL in the same run: it proves
  the fixture holds readable bytes, so a refusal elsewhere is a refusal and not
  an empty read. Refusal tests assert on the BYTES as well as the status — a
  status-only check would pass on a 200 carrying an error envelope, and a 404
  that still leaked bytes would be worse than either.

  Shared test DB: every workspace slug, ticket id and key is unique per test
  (`System.unique_integer/1`), and nothing counts whole tables.

  ## One assertion records a DEFECT, not a contract

  The final `describe` block pins the `:ticket_key` bucket's missing
  `ApiSecurityHeaders` baseline (filed as **task-5bf037daa116ea70**). Those three
  tests assert what the router does today and are expected to RED when the gap
  closes — flip them to assert presence at that point rather than deleting them.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Tickets.Attachments
  alias Barkpark.Plugins.Tickets.Keys
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  @dataset "production"

  # Real magic bytes — `Attachments.validate/2` derives the MIME from the LEADING
  # BYTES, so a fixture whose bytes lie would be refused 422 before any gate we
  # are actually testing could answer.
  @pdf <<"%PDF-1.4\n1 0 obj\n<< >>\nendobj\n">>
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <> <<0::size(256)>>

  setup :reset_rate_limiter!

  setup do
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} = Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})
    Barkpark.Plugins.Media.Codelists.seed_all()

    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)

    # Two DISTINCT live ticket keys in the SAME workspace. `other` is the
    # in-tenant attacker: a perfectly valid credential that simply does not own
    # the ticket, which is the case a tenancy-only check would wave through.
    {owner, owner_raw} = mint_key!("Kari", ws.id)
    {other, other_raw} = mint_key!("Mallory", ws.id)

    ticket = insert_ticket!(owner.id, ws, project)
    other_ticket = insert_ticket!(other.id, ws, project)

    %{
      ws: ws,
      project: project,
      owner: owner,
      owner_raw: owner_raw,
      other: other,
      other_raw: other_raw,
      ticket: ticket,
      other_ticket: other_ticket
    }
  end

  # ═══════════════════════ POST /v1/tickets/:id/attachments ═════════════════
  # (a) auth gate

  describe "POST /v1/tickets/:id/attachments — the auth gate" do
    test "anonymous (no Authorization header) → 401, and nothing is stored", ctx do
      conn = post(build_conn(), att_path(ctx.ticket), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 401
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      assert count_for(ctx) == 0
    end

    test "a garbage Bearer key → 401, byte-identical to the anonymous refusal", ctx do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer bptk_not-a-real-key")
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 401
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      assert count_for(ctx) == 0
    end

    test "a normal kind:\"api\" TOKEN is not a ticket key → 401 (the kind fence)", ctx do
      api_raw = mint_api_token!(["read", "write"], ctx.ws.id)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_raw}")
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 401
      assert count_for(ctx) == 0
    end

    test "a PAUSED key → 403 with the deliberately-distinguishable message", ctx do
      {:ok, _} = Keys.pause(ctx.owner.id, ctx.ws.id)

      conn =
        signed(ctx.owner_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 403
      body = json_response(conn, 403)
      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] == "key paused — contact the operator"
      assert count_for(ctx) == 0
    end

    test "a VALID key that does not own the ticket → 404, never 403 (no existence oracle)",
         ctx do
      conn =
        signed(ctx.other_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 404
      assert json_response(conn, 404)["error"]["code"] == "not_found"
      # The ticket EXISTS and Mallory's key is live — a 403 here would confirm
      # both facts to a stranger. It must be indistinguishable from a missing id.
      assert count_for(ctx) == 0
    end

    test "a key from ANOTHER workspace cannot write to this workspace's ticket → 404", ctx do
      other_ws = TenancyFixtures.create_workspace!()
      _ = TenancyFixtures.create_project!(other_ws)
      {_foreign, foreign_raw} = mint_key!("Outsider", other_ws.id)

      conn =
        signed(foreign_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 404
      assert count_for(ctx) == 0
    end

    test "an unknown ticket id → 404, the same envelope a foreign ticket gets", ctx do
      conn =
        signed(ctx.owner_raw)
        |> post(att_path("ticket-does-not-exist"), %{"file" => upload(@pdf, "a.pdf")})

      assert conn.status == 404
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  # (b) malformed-input arm

  describe "POST /v1/tickets/:id/attachments — malformed input never 500s" do
    test "authenticated, owns the ticket, but NO file part → 400 malformed envelope", ctx do
      conn = post(signed(ctx.owner_raw), att_path(ctx.ticket), %{})

      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"]["code"] == "malformed"
      assert body["error"]["message"] =~ "file"
    end

    test "a file whose BYTES are not an allowed type → 422, not a 500", ctx do
      # Declares image/png, but the bytes are an ELF header. The magic-byte
      # sniffer, not the declared Content-Type, decides.
      elf = <<0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00>> <> <<0::size(256)>>

      conn =
        signed(ctx.owner_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(elf, "evil.png", "image/png")})

      assert conn.status == 422
      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["details"]["reason"] in ["mime_spoofed", "mime_not_allowed"]
      assert count_for(ctx) == 0
    end

    test "an EMPTY file → 422, not a crash on zero magic bytes", ctx do
      conn =
        signed(ctx.owner_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(<<>>, "empty.pdf", "application/pdf")})

      assert conn.status == 422
      assert json_response(conn, 422)["error"]["code"] == "validation_failed"
      assert count_for(ctx) == 0
    end
  end

  # (c) happy path, read back

  describe "POST /v1/tickets/:id/attachments — happy path" do
    test "201 with the {attachment: …} envelope, and the state reads back over GET", ctx do
      created =
        signed(ctx.owner_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "invoice.pdf")})

      assert created.status == 201
      att = json_response(created, 201)["attachment"]
      assert att["content_type"] == "application/pdf"
      assert att["filename"] == "invoice.pdf"
      assert att["size"] == byte_size(@pdf)
      assert att["url"] == "/v1/tickets/#{ctx.ticket}/attachments/#{att["asset_id"]}"

      # READ THE STATE BACK through the sibling route — the 201 body is a claim,
      # the GET is the proof that the bytes actually landed and are retrievable.
      assert count_for(ctx) == 1

      read = get(signed(ctx.owner_raw), att["url"])
      assert read.status == 200
      assert response(read, 200) == @pdf
    end
  end

  # ══════════════ GET /v1/tickets/:id/attachments/:asset_id ═════════════════

  describe "GET /v1/tickets/:id/attachments/:asset_id — the auth gate" do
    setup :with_stored_attachment

    test "POSITIVE CONTROL: the owning key streams the exact bytes → 200", ctx do
      conn = get(signed(ctx.owner_raw), show_path(ctx.ticket, ctx.asset_id))

      assert conn.status == 200
      assert response(conn, 200) == @png
    end

    test "the response pins the server-derived type and forbids sniffing", ctx do
      conn = get(signed(ctx.owner_raw), show_path(ctx.ticket, ctx.asset_id))

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "image/png"
      # An allowed, non-dangerous type keeps the sanitized original name inline.
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="shot.png")]
    end

    test "anonymous → 401 and NOT the bytes", ctx do
      conn = get(build_conn(), show_path(ctx.ticket, ctx.asset_id))

      assert conn.status == 401
      refute conn.resp_body == @png
    end

    test "a VALID key that does not own the ticket → 404 and NOT the bytes", ctx do
      conn = get(signed(ctx.other_raw), show_path(ctx.ticket, ctx.asset_id))

      # The bytes are the assertion; the status is the envelope contract.
      refute conn.resp_body == @png
      assert conn.status == 404
    end

    test "a key from ANOTHER workspace → 404 and NOT the bytes", ctx do
      other_ws = TenancyFixtures.create_workspace!()
      _ = TenancyFixtures.create_project!(other_ws)
      {_foreign, foreign_raw} = mint_key!("Outsider", other_ws.id)

      conn = get(signed(foreign_raw), show_path(ctx.ticket, ctx.asset_id))

      refute conn.resp_body == @png
      assert conn.status == 404
    end

    test "the owner cannot fetch their asset THROUGH a ticket they do not own → 404", ctx do
      # `linked_asset/4` binds the asset to the ticket it was stamped for, so
      # the {ticket, asset} PAIR is checked, not just the asset.
      conn = get(signed(ctx.other_raw), show_path(ctx.other_ticket, ctx.asset_id))

      refute conn.resp_body == @png
      assert conn.status == 404
    end
  end

  describe "GET /v1/tickets/:id/attachments/:asset_id — a malformed :asset_id" do
    setup :with_stored_attachment

    # The guard this pins lives in `Media.get_file/2` (`Repo.uuid_or_nil`), and
    # was proven only at media_test.exs's context layer. THIS is the HTTP-boundary
    # assertion: a non-UUID :asset_id must be an enveloped 404, never an
    # Ecto.Query.CastError escaping as a 500.
    for {label, asset_id} <- [
          {"a plain word", "garbage"},
          {"a UUID-shaped-but-invalid string", "not-a-uuid-0000-0000-0000-000000000000"},
          {"a SQL-ish payload", "1' OR '1'='1"},
          {"an empty-ish segment", "%20"}
        ] do
      test "#{label} → 404 with the canonical envelope, never a 500", ctx do
        conn = get(signed(ctx.owner_raw), show_path(ctx.ticket, unquote(asset_id)))

        assert conn.status == 404, "expected 404, got #{conn.status}: #{conn.resp_body}"
        assert json_response(conn, 404)["error"]["code"] == "not_found"
        refute conn.resp_body == @png
      end
    end

    test "a well-formed but nonexistent UUID → the SAME 404 (no distinguishable oracle)", ctx do
      conn = get(signed(ctx.owner_raw), show_path(ctx.ticket, Ecto.UUID.generate()))

      assert conn.status == 404
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "a malformed :id (ticket) with a valid :asset_id → 404, not a 500", ctx do
      conn = get(signed(ctx.owner_raw), show_path("ticket that does not exist", ctx.asset_id))

      assert conn.status == 404
      refute conn.resp_body == @png
    end
  end

  # ══════════════════ response-header baseline (NEW FINDING) ════════════════

  describe "the :ticket_key bucket's response-header baseline" do
    setup :with_stored_attachment

    # ── NEW FINDING — task-5bf037daa116ea70 ──────────────────────────────────
    # These three assertions record what the code does TODAY, and today is
    # wrong. The `:ticket_key` pipeline (router.ex:716) is
    # `[:accepts json, RequireTicketKey, TicketRateLimit]` — it does NOT mount
    # `ApiSecurityHeaders`, so the LOWEST-trust bucket in the system (outsider
    # -held keys, outsider-supplied bytes) has a WEAKER baseline than its own
    # sibling `:session_token_root`, which serves the SAME attachment bytes to a
    # higher-trust operator and deliberately keeps the plug.
    #
    # The byte stream escapes with `nosniff` only because
    # `TicketsAttachmentsController.stream_file/2` hand-sets it — the exact
    # "an author remembering to copy a controller check" pattern the sibling
    # bucket's own comment (router.ex:800-806) says deny-by-default at the mount
    # exists to prevent.
    #
    # WHEN THIS IS FIXED these tests SHOULD red. Flip them to assert PRESENCE;
    # do not delete them — the tripwire is the point.
    test "TODAY: the JSON success envelope carries NO referrer-policy and NO nosniff", ctx do
      conn =
        signed(ctx.owner_raw)
        |> post(att_path(ctx.ticket), %{"file" => upload(@pdf, "second.pdf")})

      assert conn.status == 201
      assert get_resp_header(conn, "referrer-policy") == []
      assert get_resp_header(conn, "x-content-type-options") == []
    end

    test "TODAY: the JSON error envelope carries neither header either", ctx do
      conn = get(signed(ctx.owner_raw), show_path(ctx.ticket, "garbage"))

      assert conn.status == 404
      assert get_resp_header(conn, "referrer-policy") == []
      assert get_resp_header(conn, "x-content-type-options") == []
    end

    test "TODAY: the byte stream has nosniff (controller-set) but still NO referrer-policy",
         ctx do
      conn = get(signed(ctx.owner_raw), show_path(ctx.ticket, ctx.asset_id))

      assert conn.status == 200
      # Hand-set in stream_file/2 — this is the copied check, not the mount.
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == []
    end
  end

  # ─────────────────────────────── helpers ──────────────────────────────────

  # Store one attachment through the REAL route, so every read test below is
  # reading state the HTTP surface itself produced.
  defp with_stored_attachment(ctx) do
    conn =
      signed(ctx.owner_raw)
      |> post(att_path(ctx.ticket), %{"file" => upload(@png, "shot.png", "image/png")})

    asset_id = json_response(conn, 201)["attachment"]["asset_id"]
    %{asset_id: asset_id}
  end

  defp att_path(ticket_id), do: "/v1/tickets/#{ticket_id}/attachments"

  defp show_path(ticket_id, asset_id),
    do: "/v1/tickets/#{URI.encode(to_string(ticket_id))}/attachments/#{asset_id}"

  defp signed(raw), do: put_req_header(build_conn(), "authorization", "Bearer #{raw}")

  defp count_for(ctx),
    do: Attachments.count_for_ticket(ctx.ticket, @dataset, workspace_id: ctx.ws.id)

  defp mint_key!(name, workspace_id) do
    {:ok, %{key: key, raw: raw}} =
      Keys.mint(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        dataset: @dataset,
        workspace_id: workspace_id
      })

    {key, raw}
  end

  defp mint_api_token!(permissions, workspace_id) do
    raw = "op-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
    label = "T-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, permissions, workspace_id)
    raw
  end

  defp insert_ticket!(key_id, ws, project) do
    doc_id = "ticket-" <> Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "ticket",
      dataset: @dataset,
      status: "open",
      rev: "1",
      workspace_id: ws.id,
      project_id: project.id,
      content: %{"key_id" => to_string(key_id), "status" => "open", "messages" => []}
    })

    doc_id
  end

  defp upload(bytes, filename, content_type \\ "application/pdf") do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bptk-conn-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: filename, content_type: content_type}
  end
end
