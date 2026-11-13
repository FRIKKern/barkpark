defmodule BarkparkWeb.ChatHostAttachmentControllerTest do
  @moduledoc """
  GET /v1/chat-host/leases/:lease_id/attachments/:attachment_id
  (`/papers/chat-host-attachments-plan` T3): a registered host reads an
  attachment's bytes only through a live lease it holds.

  The named failure mode: a host credential that can name a session reads that
  session's private images. So the caller never names a session. It names a
  lease, the server takes the session from the lease row, and only a lease this
  host holds, in its own workspace, on a registered-host session its workspace
  owns and this host executes, that is still live (leased or running,
  unrevoked, unexpired) opens the store.

  Every miss answers ONE body. Each miss case below has its own test, and each
  compares against the same literal body, so a miss that answered from the
  router (no route) or from a different emitter fails here instead of passing
  as "a 404". The positive control is first: on the old code the route does not
  exist and it fails.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors, registries and /v1/chat routes
  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  # A real 1x1 PNG: the store sniffs the type from the magic bytes.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  # A second, different image, so two sessions hold two different ids.
  @gif "GIF87a" <> <<1, 0, 1, 0, 0x80, 0, 0>> <> <<0, 0, 0, 255, 255, 255, 0x3B>>

  # The one miss body, minus the per-request `request_id`. The same envelope the
  # owner route answers for a missing attachment.
  @miss %{
    "error" => %{
      "code" => "not_found",
      "message" => "chat attachment not found",
      "hint" =>
        "Check the document _id, type, and dataset in the URL — the resource does not exist in this scope."
    }
  }

  setup do
    prev = Application.get_env(:barkpark, StudioChat)

    dir =
      Path.join(
        System.tmp_dir!(),
        "bp_chat_host_attachment_test_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:barkpark, StudioChat, prev),
        else: Application.delete_env(:barkpark, StudioChat)
    end)

    ws = workspace!("hatt")
    {host, credential} = host!(ws, "runner")
    sid = host_session!(ws, host)
    {:ok, pointer} = Attachments.put(sid, @png)
    fence = lease!(host, sid)

    %{
      ws: ws,
      host: host,
      credential: credential,
      sid: sid,
      attachment_id: pointer.sha256,
      lease_id: fence.lease_id
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp workspace!(prefix) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{prefix}-#{n}", name: "#{prefix} #{n}"})
    ws
  end

  defp host!(ws, name) do
    {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: name})
    {:ok, %{credential: credential}} = ChatHosts.enroll(token)
    {:ok, host} = ChatHosts.authenticate(credential)
    {host, credential}
  end

  # A managed session: the server runs it, no host executes it.
  defp session!(ws) do
    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws.id})
    sid
  end

  # A registered-host session `host` executes, owned by `ws`. The shape a real
  # lease is minted for: dispatch resolves the host from the session's
  # `execution_host_id`.
  defp host_session!(ws, host) do
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host.id
        },
        {:workspace, ws.id}
      )

    sid
  end

  # The real lease mint, the path a registered-host dispatch rides.
  defp lease!(host, sid) do
    command = %Command{
      operation: :send_turn,
      provider: "claude",
      session_id: sid,
      idempotency_key: "hatt-#{System.unique_integer([:positive])}",
      payload: %{}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  # A lease row written directly, for shapes the dispatch path never mints (a
  # lease whose workspace or session disagrees with the host's). Each such
  # test isolates ONE fence leg: every other column is live and matching.
  defp raw_lease!(attrs) do
    base = %{
      provider: "claude",
      command_key: "hatt-raw-#{System.unique_integer([:positive])}",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    %ExecutionLease{} |> ExecutionLease.changeset(Map.merge(base, attrs)) |> Repo.insert!()
  end

  defp set_lease!(lease_id, fields) do
    {1, _} = Repo.update_all(from(l in ExecutionLease, where: l.id == ^lease_id), set: fields)
  end

  defp host_path(lease_id, attachment_id),
    do: "/v1/chat-host/leases/#{lease_id}/attachments/#{attachment_id}"

  defp as_host(credential) do
    scoped_conn() |> put_req_header("authorization", "Host #{credential}")
  end

  defp read(credential, lease_id, attachment_id) do
    as_host(credential) |> get(host_path(lease_id, attachment_id))
  end

  defp miss_body(conn) do
    conn |> json_response(404) |> update_in(["error"], &Map.delete(&1, "request_id"))
  end

  # ── the positive control ────────────────────────────────────────────────────

  test "the leasing host reads the bytes of an attachment in its leased session",
       %{credential: credential, lease_id: lease_id, attachment_id: attachment_id} do
    body = read(credential, lease_id, attachment_id) |> json_response(200)

    # Exactly four keys: no url (the host cannot read the owner route), no
    # store path, no session id.
    assert body == %{
             "attachment" => %{
               "id" => attachment_id,
               "media_type" => "image/png",
               "byte_size" => byte_size(@png),
               "data" => Base.encode64(@png)
             }
           }

    assert :crypto.hash(:sha256, Base.decode64!(body["attachment"]["data"]))
           |> Base.encode16(case: :lower) == attachment_id
  end

  test "a running lease reads the same bytes as a freshly leased one",
       %{credential: credential, lease_id: lease_id, attachment_id: attachment_id} do
    set_lease!(lease_id, status: "running")

    assert read(credential, lease_id, attachment_id)
           |> json_response(200)
           |> get_in(["attachment", "data"]) == Base.encode64(@png)
  end

  # ── tenancy: whose lease ────────────────────────────────────────────────────

  test "another host's lease answers the not-found body", %{
    ws: ws,
    lease_id: lease_id,
    attachment_id: attachment_id
  } do
    {_intruder, intruder_credential} = host!(ws, "intruder")

    assert read(intruder_credential, lease_id, attachment_id) |> miss_body() == @miss
  end

  test "a host in another workspace naming this lease answers the not-found body", %{
    lease_id: lease_id,
    attachment_id: attachment_id
  } do
    {_other, other_credential} = host!(workspace!("hatt-other"), "other")

    assert read(other_credential, lease_id, attachment_id) |> miss_body() == @miss
  end

  test "a lease row stamped with another workspace answers the not-found body",
       %{host: host, credential: credential, sid: sid, attachment_id: attachment_id} do
    # host_id, session, status, expiry all match; only workspace_id disagrees.
    other_ws = workspace!("hatt-lease-ws")

    lease =
      raw_lease!(%{host_id: host.id, workspace_id: other_ws.id, session_id: sid})

    assert read(credential, lease.id, attachment_id) |> miss_body() == @miss
  end

  test "a lease on a session another workspace owns answers the not-found body",
       %{host: host, ws: ws, credential: credential} do
    # The lease row names this host and this workspace, and the session names
    # this host as its executor, but it belongs to another workspace, and holds
    # a real attachment. Only the owner leg refuses it.
    foreign_sid = host_session!(workspace!("hatt-foreign"), host)
    {:ok, pointer} = Attachments.put(foreign_sid, @gif)

    lease = raw_lease!(%{host_id: host.id, workspace_id: ws.id, session_id: foreign_sid})

    assert read(credential, lease.id, pointer.sha256) |> miss_body() == @miss
  end

  test "a lease for this host on a session another host executes answers the not-found body",
       %{host: host, ws: ws, credential: credential} do
    # Same workspace, live lease row naming this host, but the session's
    # executor is host B: the lease row's host is a copy, the session's
    # execution_host_id is the truth.
    {host_b, _} = host!(ws, "executor-b")
    sid = host_session!(ws, host_b)
    {:ok, pointer} = Attachments.put(sid, @gif)

    lease = raw_lease!(%{host_id: host.id, workspace_id: ws.id, session_id: sid})

    assert read(credential, lease.id, pointer.sha256) |> miss_body() == @miss
  end

  test "another host's lease on a session this host executes answers the not-found body",
       %{host: host, ws: ws} do
    # The caller (B) executes the session; the live lease row belongs to this
    # setup's host (A). Only the lease's own host leg refuses B.
    {executor, executor_credential} = host!(ws, "executor")
    sid = host_session!(ws, executor)
    {:ok, pointer} = Attachments.put(sid, @gif)

    lease = raw_lease!(%{host_id: host.id, workspace_id: ws.id, session_id: sid})

    assert read(executor_credential, lease.id, pointer.sha256) |> miss_body() == @miss
  end

  test "a lease for this host on a managed session answers the not-found body",
       %{host: host, ws: ws, credential: credential} do
    # The server runs a managed session; no host executes it, so no host lease
    # opens its store.
    sid = session!(ws)
    {:ok, pointer} = Attachments.put(sid, @gif)

    lease = raw_lease!(%{host_id: host.id, workspace_id: ws.id, session_id: sid})

    assert read(credential, lease.id, pointer.sha256) |> miss_body() == @miss
  end

  test "an attachment from a session this lease does not cover answers the not-found body",
       %{ws: ws, credential: credential, lease_id: lease_id} do
    # Same host, same workspace, a real attachment, but in a different
    # session: the lease's session is the only store the read opens.
    other_sid = session!(ws)
    {:ok, pointer} = Attachments.put(other_sid, @gif)

    assert read(credential, lease_id, pointer.sha256) |> miss_body() == @miss
  end

  # ── liveness: replay after the turn ended ───────────────────────────────────

  for status <- ~w(completed cancelled disconnected) do
    test "a #{status} lease answers the not-found body",
         %{credential: credential, lease_id: lease_id, attachment_id: attachment_id} do
      set_lease!(lease_id, status: unquote(status))

      assert read(credential, lease_id, attachment_id) |> miss_body() == @miss
    end
  end

  test "an expired lease answers the not-found body",
       %{credential: credential, lease_id: lease_id, attachment_id: attachment_id} do
    set_lease!(lease_id, expires_at: DateTime.add(DateTime.utc_now(), -5, :second))

    assert read(credential, lease_id, attachment_id) |> miss_body() == @miss
  end

  test "a revoked lease, still marked leased, answers the not-found body",
       %{credential: credential, lease_id: lease_id, attachment_id: attachment_id} do
    set_lease!(lease_id, revoked_at: DateTime.utc_now())

    assert read(credential, lease_id, attachment_id) |> miss_body() == @miss
  end

  # ── malformed and unknown ids ───────────────────────────────────────────────

  test "an unknown lease id answers the not-found body",
       %{credential: credential, attachment_id: attachment_id} do
    assert read(credential, Ecto.UUID.generate(), attachment_id) |> miss_body() == @miss
  end

  test "a malformed lease id answers the not-found body",
       %{credential: credential, attachment_id: attachment_id} do
    assert read(credential, "not-a-uuid", attachment_id) |> miss_body() == @miss
    assert read(credential, "..", attachment_id) |> miss_body() == @miss
  end

  test "a missing attachment answers the not-found body",
       %{credential: credential, lease_id: lease_id} do
    absent = :crypto.hash(:sha256, "never stored") |> Base.encode16(case: :lower)

    assert read(credential, lease_id, absent) |> miss_body() == @miss
  end

  test "a ../ attachment id into another session's store answers the not-found body",
       %{ws: ws, credential: credential, lease_id: lease_id, attachment_id: attachment_id} do
    other_sid = session!(ws)
    {:ok, pointer} = Attachments.put(other_sid, @gif)

    # %2F decodes inside the one path segment, so the param is
    # "../<other_sid>/<sha>": a walk out of the leased session's directory.
    traversal = "..%2F#{other_sid}%2F#{pointer.sha256}"
    assert read(credential, lease_id, traversal) |> miss_body() == @miss

    # Not a 64-char lowercase hex id: refused before the store.
    assert read(credential, lease_id, String.upcase(attachment_id)) |> miss_body() == @miss
    assert read(credential, lease_id, "..") |> miss_body() == @miss
  end

  # ── credentials: which door ─────────────────────────────────────────────────

  test "a revoked host is refused by the host pipeline before the route",
       %{ws: ws, host: host, credential: credential, lease_id: lease_id} = ctx do
    {:ok, _} = ChatHosts.revoke(ws.id, host.id)

    body = read(credential, lease_id, ctx.attachment_id) |> json_response(401)
    assert body["error"]["code"] == "unauthorized"
    refute Map.has_key?(body, "attachment")
  end

  test "a bearer token on the host route is 401",
       %{lease_id: lease_id, attachment_id: attachment_id} do
    raw = "hatt-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "hatt-admin", "production", ["read", "write", "admin"])

    body =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get(host_path(lease_id, attachment_id))
      |> json_response(401)

    assert body["error"]["code"] == "unauthorized"
    refute Map.has_key?(body, "attachment")
  end

  test "a host credential on the owner attachment route is refused",
       %{credential: credential, sid: sid, attachment_id: attachment_id} do
    conn = as_host(credential) |> get("/v1/chat/sessions/#{sid}/attachments/#{attachment_id}")

    assert conn.status == 401
    refute Map.has_key?(json_response(conn, 401), "attachment")
  end
end
