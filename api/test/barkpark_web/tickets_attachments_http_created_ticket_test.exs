defmodule BarkparkWeb.TicketsAttachmentsHttpCreatedTicketTest do
  @moduledoc """
  A ticket filed over HTTP must be reachable by its OWN attachment routes
  (task-0d7d25398ee8dfde).

  `Barkpark.Plugins.Tickets.Thread.create/2` writes through
  `Content.create_document/4`, and "new docs are always created as drafts" — so
  the stored row is `drafts.ticket-…` while the id handed back to the submitter
  (`Thread.to_map/1` → `Content.published_id/1`) is the bare `ticket-…`.
  `TicketsAttachmentsController.owned_ticket/2` and `operator_ticket/3`
  resolved that bare id straight through `Content.get_document/4`, which
  matches the `doc_id` column EXACTLY — so the submitter who had just been
  handed the id got **404 not_found** the moment they tried to attach a file to
  it.

  Every sibling suite dodged this by seeding the ticket ROW directly with a
  published-shaped `ticket-…` doc_id (`tickets_attachments_session_pipeline_test.exs`,
  `ticket_key_security_headers_test.exs`, `attachments_test.exs`), which is
  precisely why no gate caught it. THIS suite inserts no rows: both the ticket
  and the attachment are created through `BarkparkWeb.Endpoint`, with the id
  the API itself returned.

  RED-BEFORE (on main, every test below except the refusals):

      Assertion with == failed
      code:  assert conn.status == 201
      left:  404
      right: 201

  The refusal tests are the discrimination half: widening the lookup must not
  hand a foreign key someone else's ticket or bytes. Note that "POST an
  attachment to someone else's ticket → 404" is VACUOUSLY green before the fix
  (on main every id 404s, owner or not); it only starts discriminating once the
  positive tests above it can pass.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.RateLimiterSandbox
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Tickets.Keys
  alias Barkpark.TenancyFixtures

  @endpoint BarkparkWeb.Endpoint

  @dataset "production"
  @pdf <<"%PDF-1.4\n1 0 obj\n<< >>\nendobj\n">>

  setup :reset_rate_limiter!

  setup do
    :ok =
      Barkpark.Plugins.Registry.register(
        Barkpark.Plugins.Media,
        Barkpark.Plugins.Media.manifest()
      )

    {:ok, _} = Bootstrap.install_for_plugin(%{name: "media", module: Barkpark.Plugins.Media})
    Barkpark.Plugins.Media.Codelists.seed_all()

    # A generous budget so neither the IP meter nor the per-key TicketRateLimit
    # can turn one of these outcomes into a stray 429.
    :ets.delete_all_objects(:barkpark_rate_limiter)

    prev = Application.get_env(:barkpark, :rate_limits, [])
    prev_ticket = Application.get_env(:barkpark, :ticket_rate_limits, [])

    Application.put_env(:barkpark, :rate_limits,
      read_per_minute: 1_000_000,
      write_per_minute: 1_000_000
    )

    Application.put_env(:barkpark, :ticket_rate_limits,
      create: 100_000,
      message: 100_000,
      attachment: 100_000
    )

    on_exit(fn ->
      Application.put_env(:barkpark, :rate_limits, prev)
      Application.put_env(:barkpark, :ticket_rate_limits, prev_ticket)
    end)

    {ws, _project} = TenancyFixtures.ensure_default_scope!()
    register_ticket_schema!(workspace_id: ws.id)

    {:ok, %{key: _key, raw: raw}} =
      Keys.mint(%{name: "Kari", workspace_id: ws.id, dataset: @dataset})

    {:ok, %{key: _other, raw: other_raw}} =
      Keys.mint(%{name: "Nils", workspace_id: ws.id, dataset: @dataset})

    %{ws: ws, raw: raw, other_raw: other_raw}
  end

  # ── criterion 0: file a ticket over HTTP, then attach to it ──────────────

  test "POST /v1/tickets then POST /v1/tickets/:id/attachments with the SAME key → 201",
       %{raw: raw} do
    ticket_id = file_ticket!(raw)

    conn =
      raw
      |> keyed_conn()
      |> post("/v1/tickets/#{ticket_id}/attachments", %{
        "file" => upload(@pdf, "doc.pdf", "application/pdf")
      })

    assert conn.status == 201,
           "a ticket filed at POST /v1/tickets must be reachable by its own " <>
             "attachment route; got #{conn.status}: #{conn.resp_body}"

    assert json_response(conn, 201)["attachment"]["asset_id"]
  end

  # ── criterion 2: read the bytes back, and only with the owning key ───────

  test "GET /v1/tickets/:id/attachments/:asset_id returns the BYTES to the owning key",
       %{raw: raw} do
    {ticket_id, asset_id} = file_ticket_with_attachment!(raw)

    conn = raw |> keyed_conn() |> get("/v1/tickets/#{ticket_id}/attachments/#{asset_id}")

    assert conn.status == 200
    assert response(conn, 200) == @pdf
  end

  test "GET the same attachment with a NON-OWNING ticket key → 404, never the bytes",
       %{raw: raw, other_raw: other_raw} do
    {ticket_id, asset_id} = file_ticket_with_attachment!(raw)

    conn = other_raw |> keyed_conn() |> get("/v1/tickets/#{ticket_id}/attachments/#{asset_id}")

    # The BYTES are the assertion — a status-only check would pass on a 200
    # carrying an error envelope, and a leaking 404 would be worse.
    refute conn.resp_body == @pdf
    assert conn.status == 404
  end

  test "POST an attachment to someone else's HTTP-filed ticket → 404 (no upload)",
       %{raw: raw, other_raw: other_raw} do
    ticket_id = file_ticket!(raw)

    conn =
      other_raw
      |> keyed_conn()
      |> post("/v1/tickets/#{ticket_id}/attachments", %{
        "file" => upload(@pdf, "doc.pdf", "application/pdf")
      })

    assert conn.status == 404
  end

  # ── the operator half of "the attachment routes" ─────────────────────────

  test "the operator inbox route streams the attachment of an HTTP-filed ticket",
       %{raw: raw, ws: ws} do
    {ticket_id, asset_id} = file_ticket_with_attachment!(raw)
    operator_raw = mint_operator_token!(ws.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{operator_raw}")
      |> get("/v1/tickets/inbox/#{ticket_id}/attachments/#{asset_id}")

    assert conn.status == 200
    assert response(conn, 200) == @pdf
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # File a ticket the way a submitter does — through the endpoint — and return
  # the id the API HANDED BACK. No row is inserted anywhere in this suite; that
  # is the whole point.
  defp file_ticket!(raw) do
    conn =
      raw
      |> keyed_conn()
      |> post("/v1/tickets", %{"subject" => "Login broken", "body" => "I can't sign in"})

    assert conn.status == 201, "fixture: POST /v1/tickets failed: #{conn.resp_body}"
    id = json_response(conn, 201)["ticket"]["id"]
    assert is_binary(id) and id != ""
    id
  end

  defp file_ticket_with_attachment!(raw) do
    ticket_id = file_ticket!(raw)

    conn =
      raw
      |> keyed_conn()
      |> post("/v1/tickets/#{ticket_id}/attachments", %{
        "file" => upload(@pdf, "doc.pdf", "application/pdf")
      })

    assert conn.status == 201,
           "fixture: attaching to the just-filed ticket failed: #{conn.resp_body}"

    {ticket_id, json_response(conn, 201)["attachment"]["asset_id"]}
  end

  defp mint_operator_token!(workspace_id) do
    raw = "op-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
    {:ok, _} = Auth.create_token(raw, "Support Desk", @dataset, ["read"], workspace_id)
    raw
  end

  defp keyed_conn(raw), do: put_req_header(build_conn(), "authorization", "Bearer #{raw}")

  defp register_ticket_schema!(scope) do
    for schema_def <- Barkpark.Plugins.Tickets.register_schemas([]) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp upload(bytes, filename, content_type) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bptk-http-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: filename, content_type: content_type}
  end
end
