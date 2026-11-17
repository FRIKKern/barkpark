defmodule BarkparkWeb.DatasetBoundChatHostWritesTest do
  @moduledoc """
  A dataset-bound admin token holding the owner seat, on the workspace chat
  hosts: enrolling a host (a workspace credential) and revoking one.

  `:observe` (the default) lets both through and records one audit row each.
  `:enforce` refuses with 403 `dataset_not_bound` and changes nothing. An
  unbound owner token does both in either mode, unrecorded. The rule itself is
  `BarkparkWeb.Plugs.DatasetBoundAdminWrites`; the other writes are in
  `BarkparkWeb.DatasetBoundAdminWritesTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the /w/:ws/v1/chat-hosts routes.
  @moduletag :requires_plugins
  @moduletag :capture_log

  import Ecto.Query

  alias Barkpark.{Auth, ChatHosts, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Plugs.DatasetBoundAdminWrites

  @admin ["read", "write", "admin"]

  setup do
    TenancyFixtures.ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "bound-hosts-#{suffix}", name: "Hosts"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    previous = Application.get_env(:barkpark, :dataset_bound_admin_reads)
    on_exit(fn -> Application.put_env(:barkpark, :dataset_bound_admin_reads, previous) end)

    {:ok, ws: ws, bound: owner!(ws, dataset_bound: true), unbound: owner!(ws, [])}
  end

  defp owner!(ws, opts) do
    raw = "bound-hosts-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bound hosts", "production", @admin, nil, opts)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    %{raw: raw, id: token.id}
  end

  defp send_as(raw, method, path, body) do
    scoped_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> raw)
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp records,
    do: Repo.all(from(e in Event, where: e.action == ^DatasetBoundAdminWrites.action()))

  defp enroll(ctx, token) do
    send_as(token.raw, :post, "/w/#{ctx.ws.slug}/v1/chat-hosts/enrollments", %{
      name: "laptop",
      approved_roots: [System.tmp_dir!()]
    })
  end

  defp revoke(ctx, token) do
    {:ok, %{host: %{id: id}}} = ChatHosts.issue_enrollment(ctx.ws.id, %{name: "old box"})
    send_as(token.raw, :delete, "/w/#{ctx.ws.slug}/v1/chat-hosts/#{id}", %{})
  end

  defp refused!(conn) do
    assert conn.status == 403, conn.resp_body
    assert Jason.decode!(conn.resp_body)["error"]["reason"] == "dataset_not_bound"
  end

  defp hosts(ctx), do: ChatHosts.list_hosts(ctx.ws.id)

  test "observe: a bound owner token enrolls and revokes, one audit row each", ctx do
    assert enroll(ctx, ctx.bound).status == 201
    assert [_] = hosts(ctx)
    assert revoke(ctx, ctx.bound).status == 200
    assert [_] = hosts(ctx)

    rows = records()
    assert length(rows) == 2

    for row <- rows do
      assert row.actor_id == ctx.bound.id
      assert row.workspace_id == ctx.ws.id
      assert row.metadata["surface"] == "tokens_write"
    end
  end

  test "enforce: a bound owner token gets 403 dataset_not_bound and no host changes", ctx do
    Application.put_env(:barkpark, :dataset_bound_admin_reads, :enforce)

    refused!(enroll(ctx, ctx.bound))
    assert hosts(ctx) == []
    refused!(revoke(ctx, ctx.bound))
    assert [_] = hosts(ctx)
    assert records() == []
  end

  for mode <- [:observe, :enforce] do
    test "#{mode}: an unbound owner token enrolls and revokes, unrecorded", ctx do
      Application.put_env(:barkpark, :dataset_bound_admin_reads, unquote(mode))
      assert enroll(ctx, ctx.unbound).status == 201
      assert revoke(ctx, ctx.unbound).status == 200
      assert [_] = hosts(ctx)
      assert records() == []
    end
  end
end
