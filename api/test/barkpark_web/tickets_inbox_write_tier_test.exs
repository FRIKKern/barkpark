defmodule BarkparkWeb.TicketsInboxWriteTierTest do
  @moduledoc """
  Owner ruling #24 (2026-10-03, task-eec10eeab544e619 Q1): reading the ticket
  operator inbox needs the write tier.

  The inbox holds outside submitters' threads and uploaded files. Answering a
  ticket already needed write (`POST` rides `RequireWriteForMutation`), but the
  three operator READS — the inbox list, one thread, and an attachment
  download — admitted any token with `read`. Each test dispatches through the
  real endpoint, and each refusal is paired with a write-token positive control
  on the same fixture.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.RateLimiterSandbox
  import Phoenix.ConnTest
  import Plug.Conn

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.TicketsAttachmentsController, as: Controller

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
    :ets.delete_all_objects(:barkpark_rate_limiter)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    key = %{id: "key-A", dataset: @dataset, workspace_id: ws.id, project_id: project.id}
    ticket = insert_ticket!(key.id, ws, project)

    created =
      Controller.create(assign(build_conn(), :ticket_key, key), %{
        "id" => ticket,
        "file" => upload(@pdf)
      })

    asset_id = json_response(created, 201)["attachment"]["asset_id"]

    %{
      ws: ws,
      ticket: ticket,
      attachment: "/v1/tickets/inbox/#{ticket}/attachments/#{asset_id}"
    }
  end

  defp get_as(raw, path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get(path)
  end

  defp assert_forbidden(conn) do
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "forbidden"
  end

  test "a read-only token cannot list the inbox", %{ws: ws} do
    assert_forbidden(get_as(mint_token!(["read"], ws.id), "/v1/tickets/inbox"))
  end

  test "a read-only token cannot read one thread", %{ws: ws, ticket: ticket} do
    assert_forbidden(get_as(mint_token!(["read"], ws.id), "/v1/tickets/inbox/#{ticket}"))
  end

  test "a read-only token cannot download an attachment, by bearer or session cookie",
       %{ws: ws, attachment: path} do
    raw = mint_token!(["read"], ws.id)

    conn = get_as(raw, path)
    assert_forbidden(conn)
    refute conn.resp_body == @pdf

    conn = build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw}) |> get(path)
    assert_forbidden(conn)
  end

  test "a write token lists the inbox, reads the thread, and downloads the attachment",
       %{ws: ws, ticket: ticket, attachment: path} do
    raw = mint_token!(["read", "write"], ws.id)

    conn = get_as(raw, "/v1/tickets/inbox")
    assert conn.status == 200
    assert Enum.any?(Jason.decode!(conn.resp_body)["tickets"], &(&1["id"] == ticket))

    assert get_as(raw, "/v1/tickets/inbox/#{ticket}").status == 200

    conn = get_as(raw, path)
    assert conn.status == 200
    assert conn.resp_body == @pdf

    conn = build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw}) |> get(path)
    assert conn.status == 200
  end

  test "an admin token keeps reading the inbox", %{ws: ws} do
    assert get_as(mint_token!(["read", "write", "admin"], ws.id), "/v1/tickets/inbox").status ==
             200
  end

  test "an anonymous download is still 401, not 403", %{attachment: path} do
    assert build_conn() |> get(path) |> Map.get(:status) == 401
  end

  defp mint_token!(permissions, workspace_id) do
    raw = "op-" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
    {:ok, _} = Auth.create_token(raw, "Support Desk", @dataset, permissions, workspace_id)
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
      content: %{"key_id" => key_id, "status" => "open", "messages" => []}
    })

    doc_id
  end

  defp upload(bytes) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "bptk-tier-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.write!(tmp, bytes)
    on_exit(fn -> File.rm(tmp) end)
    %Plug.Upload{path: tmp, filename: "doc.pdf", content_type: "application/pdf"}
  end
end
