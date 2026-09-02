defmodule BarkparkWeb.TicketKeySecurityHeadersTest do
  @moduledoc """
  The `:ticket_key` bucket's baseline response headers (task-5bf037daa116ea70).

  `:ticket_key` was the one browser-reachable `/v1` pipeline that did NOT mount
  `BarkparkWeb.Plugs.ApiSecurityHeaders` — and it is the LOWEST-trust bucket in
  the system: outsider-held keys uploading and downloading outsider-supplied
  bytes. Its direct sibling `:session_token_root`, which serves the SAME
  attachment bytes to a HIGHER-trust operator principal, mounts the plug
  deliberately.

  Before the fix the only response on this surface carrying
  `x-content-type-options` was the attachment byte stream, and it carried it
  because `TicketsAttachmentsController.stream_file/2` hand-sets the header —
  never because the mount guaranteed it. Nothing carried `referrer-policy`. The
  durable risk is structural: a second byte-serving GET added to this bucket
  ships with NO nosniff unless its author remembers to copy that controller
  check. Deny-by-default belongs at the MOUNT.

  Every test dispatches a REAL request through `BarkparkWeb.Endpoint`, so what
  is asserted is the mounted pipeline and not a hand-built conn. The 201/200
  status assertions are the positive control in the same run: they prove the
  fixture is real, so a header assertion is about a response that actually did
  the work rather than an early refusal.

  MUTATION-PROVEN: deleting `plug(BarkparkWeb.Plugs.ApiSecurityHeaders)` from
  the `:ticket_key` pipeline reds every test below except the byte stream's
  `nosniff` (which the controller still hand-sets) — i.e. it reds the
  `referrer-policy` half of the stream too, which is exactly the coverage the
  hand-set header never bought.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.RateLimiterSandbox
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Tickets.Keys
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  @endpoint BarkparkWeb.Endpoint

  @dataset "production"
  @pdf <<"%PDF-1.4\n1 0 obj\n<< >>\nendobj\n">>

  # The two headers `ApiSecurityHeaders` exists to guarantee.
  @nosniff {"x-content-type-options", "nosniff"}
  @referrer {"referrer-policy", "strict-origin-when-cross-origin"}

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
    # can turn one of these into a stray 429 masquerading as a header outcome.
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

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    register_ticket_schema!(workspace_id: ws.id)

    {:ok, %{key: key, raw: raw}} =
      Keys.mint(%{name: "Kari", workspace_id: ws.id, dataset: @dataset})

    %{ws: ws, project: project, key: key, raw: raw}
  end

  # ── the JSON envelope half ────────────────────────────────────────────────

  test "POST /v1/tickets (the submitter JSON envelope) carries both headers", %{raw: raw} do
    conn =
      raw
      |> keyed_conn()
      |> post("/v1/tickets", %{"subject" => "Login broken", "body" => "I can't sign in"})

    # Positive control: this is a real 201, not a refusal that never rendered.
    assert conn.status == 201
    assert json_response(conn, 201)["ticket"]["status"] == "open"

    assert_baseline_headers(conn)
  end

  test "GET /v1/tickets (the submitter read) carries both headers", %{raw: raw} do
    conn = raw |> keyed_conn() |> get("/v1/tickets")

    assert conn.status == 200
    assert_baseline_headers(conn)
  end

  test "POST /v1/tickets/:id/attachments (the upload's 201 JSON) carries both headers",
       %{raw: raw} = ctx do
    ticket = insert_ticket!(ctx)

    conn =
      raw
      |> keyed_conn()
      |> post("/v1/tickets/#{ticket}/attachments", %{
        "file" => upload(@pdf, "doc.pdf", "application/pdf")
      })

    assert conn.status == 201
    assert json_response(conn, 201)["attachment"]["asset_id"]

    assert_baseline_headers(conn)
  end

  # ── the BYTE STREAM half — the response the controller hand-covered ───────

  test "GET /v1/tickets/:id/attachments/:asset_id (the byte stream) carries both headers",
       %{raw: raw} = ctx do
    {ticket, asset_id} = ticket_with_attachment!(ctx)

    conn = raw |> keyed_conn() |> get("/v1/tickets/#{ticket}/attachments/#{asset_id}")

    # Positive control: the fixture really streams the bytes back, so the
    # header assertions below are about a genuine 200 byte response.
    assert conn.status == 200
    assert response(conn, 200) == @pdf

    # `nosniff` was already here before the mount (stream_file/2 hand-sets it);
    # `referrer-policy` is what the mount adds, and the plug's
    # never-overwrite rule means the controller's own nosniff still wins.
    assert_baseline_headers(conn)
  end

  # ── the ERROR ENVELOPES — the halting plug's own responses ────────────────

  test "the 401 from RequireTicketKey (no key at all) carries both headers" do
    conn = build_conn() |> get("/v1/tickets")

    assert conn.status == 401
    assert_baseline_headers(conn)
  end

  test "a 404 error envelope on the submitter surface carries both headers", %{raw: raw} do
    conn = raw |> keyed_conn() |> get("/v1/tickets/ticket-does-not-exist")

    assert conn.status == 404
    assert_baseline_headers(conn)
  end

  # ── the sibling that already had it stays byte-identical ─────────────────

  test "the higher-trust sibling :session_token_root still carries both headers" do
    # A 401 on the operator route is enough — the assertion is about the MOUNT,
    # and this bucket's baseline must not regress while :ticket_key gains one.
    conn = build_conn() |> get("/v1/tickets/inbox/nope/attachments/nope")

    assert conn.status in [401, 404]
    assert_baseline_headers(conn)
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp assert_baseline_headers(conn) do
    {nosniff_name, nosniff_value} = @nosniff
    {referrer_name, referrer_value} = @referrer

    assert get_resp_header(conn, nosniff_name) == [nosniff_value],
           "#{conn.method} #{conn.request_path} (#{conn.status}) is missing " <>
             "#{nosniff_name}: got #{inspect(get_resp_header(conn, nosniff_name))}"

    assert get_resp_header(conn, referrer_name) == [referrer_value],
           "#{conn.method} #{conn.request_path} (#{conn.status}) is missing " <>
             "#{referrer_name}: got #{inspect(get_resp_header(conn, referrer_name))}"
  end

  defp keyed_conn(raw), do: put_req_header(build_conn(), "authorization", "Bearer #{raw}")

  # The attachment fixture inserts the ticket ROW directly, exactly as
  # `attachments_test.exs` and `tickets_attachments_session_pipeline_test.exs`
  # do. `Thread.create/2` writes a `drafts.`-prefixed row while
  # `TicketsAttachmentsController.owned_ticket/2` resolves the PUBLISHED id, so
  # a ticket filed over HTTP is not reachable by the attachment routes — a real,
  # separate defect and not this test's subject. The REQUESTS below still go
  # through the endpoint; only the ticket row is seeded.
  defp insert_ticket!(%{key: key, ws: ws, project: project}) do
    doc_id = "ticket-" <> Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "ticket",
      dataset: @dataset,
      status: "open",
      rev: "1",
      workspace_id: ws.id,
      project_id: project.id,
      content: %{"key_id" => key.id, "status" => "open", "messages" => []}
    })

    doc_id
  end

  defp ticket_with_attachment!(%{raw: raw} = ctx) do
    ticket = insert_ticket!(ctx)

    conn =
      raw
      |> keyed_conn()
      |> post("/v1/tickets/#{ticket}/attachments", %{
        "file" => upload(@pdf, "doc.pdf", "application/pdf")
      })

    {ticket, json_response(conn, 201)["attachment"]["asset_id"]}
  end

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
        "bptk-hdr-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: filename, content_type: content_type}
  end
end
