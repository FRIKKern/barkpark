defmodule BarkparkWeb.Integration.FlatListenGrantNarrowingTest do
  @moduledoc """
  Realtime authz sweep (r4a): the FLAT listen stream did not narrow a grantee.

  `GET /v1/data/listen/:dataset` was mounted on `[:api, :require_token]`. A
  workspace-less personal token whose owner holds a narrow grant on Default is
  admitted there (`DeriveWorkspaceFromToken.grant_covers_read?`), and that
  plug's own comment says the flat routes then narrow the caller through
  `AssignGrantScope`. Listen never ran that plug, so `:grant_scoped` was never
  set, `ListenController`'s grant drop never fired, and a grantee holding ONE
  type on Default streamed the WHOLE Default workspace: every type, both on the
  replay leg (`lastEventId=0`, the full event history) and live.

  The scoped mirror was already narrowed (`listen_grant_narrowing_test.exs`).
  The fix mounts the flat listen route on `:api_grant_read`, the pipeline its
  sibling flat read (analytics) already uses.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Auth.ApiToken

  setup do
    {ws, project} = ensure_default_scope!()
    n = System.unique_integer([:positive])
    ds = "flatlisten#{n}"
    in_type = "grantedMemo#{n}"
    out_type = "ledgerSecret#{n}"

    {:ok, doc_in} = create_document_in!(ws, project, in_type, %{"title" => "in"}, ds)
    {:ok, doc_out} = create_document_in!(ws, project, out_type, %{"title" => "out"}, ds)

    {:ok, ws: ws, project: project, ds: ds, in_type: in_type, doc_in: doc_in, doc_out: doc_out}
  end

  defp owned_token!(user) do
    raw = "flat-listen-" <> Ecto.UUID.generate()

    {:ok, _token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "flat-listen",
        dataset: "test",
        permissions: ["read"],
        owner_user_id: user.id
      })
      |> Repo.insert()

    raw
  end

  defp grantee_raw(ctx) do
    email = "flat-listen-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    bind_grant!(ctx.ws, user, %{
      project_id: ctx.project.id,
      dataset: ctx.ds,
      type: ctx.in_type,
      capabilities: ["read"]
    })

    owned_token!(user)
  end

  defp replay_body(conn, raw, ds) do
    conn = put_req_header(conn, "authorization", "Bearer " <> raw)
    task = Task.async(fn -> get(conn, "/v1/data/listen/#{ds}", %{"lastEventId" => "0"}) end)
    send(task.pid, :sse_overloaded)
    conn = Task.await(task, 20_000)
    {conn.status, conn.resp_body}
  end

  defp doc_ids(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&Jason.decode!(String.replace_prefix(&1, "data: ", "")))
    |> Enum.map(& &1["documentId"])
    |> Enum.reject(&is_nil/1)
  end

  test "a grantee on the flat route gets no frame for a type outside the grant", ctx do
    {status, body} = replay_body(ctx.conn, grantee_raw(ctx), ctx.ds)
    assert status == 200, "precondition: the grantee must reach the stream (got #{status})"
    assert body =~ "event: welcome"

    refute ctx.doc_out.doc_id in doc_ids(body),
           "the flat listen stream replayed a document outside the caller's grant"
  end

  test "the grantee still receives the granted type (control)", ctx do
    {200, body} = replay_body(ctx.conn, grantee_raw(ctx), ctx.ds)
    assert ctx.doc_in.doc_id in doc_ids(body)
  end

  test "a Default member still receives every type (control)", ctx do
    raw = "flat-listen-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "flat-listen-member", "test", ["read"], ctx.ws.id)
    {200, body} = replay_body(ctx.conn, raw, ctx.ds)
    assert ctx.doc_out.doc_id in doc_ids(body)
  end
end
