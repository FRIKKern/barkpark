defmodule BarkparkWeb.ChatHostIdCastTest do
  @moduledoc """
  Chat-host lookups by an id the caller typed (task-34f964e9d66f48e4).

  The named failure mode: `ChatHosts.get_host/2` compared a raw string against
  a `:binary_id` column, so a malformed id raised Ecto.Query.CastError. An
  owner's `DELETE /w/:ws/v1/chat-hosts/not-a-uuid` answered a plain 400
  instead of the typed 404, and a revoke with such an id crashed the owner's
  ChatHostsLive. The same shape sat in the host's event POST (`lease_id` from
  the body; a missing one reached `l.id == ^nil`, which Ecto refuses) and in
  the state report (`:id` from the path).

  A malformed id now reads as "no such row", and each route answers what it
  answers for a well-formed id that matches nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-cast-#{suffix}", name: "Cast"})
    {:ok, _project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    owner_raw = "host-cast-owner-#{suffix}"
    {:ok, owner} = Auth.create_token(owner_raw, "owner", "production", ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: "laptop", approved_roots: [System.tmp_dir!()]})

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token)

    %{ws: ws, owner_raw: owner_raw, host_id: issued.host.id, credential: enrolled.credential}
  end

  describe "DELETE /w/:ws/v1/chat-hosts/:id" do
    test "a malformed id is the typed 404 not_found, and nothing is revoked", ctx do
      conn = bearer(ctx.owner_raw) |> delete("/w/#{ctx.ws.slug}/v1/chat-hosts/not-a-uuid")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
      assert is_nil(Repo.get!(RegisteredHost, ctx.host_id).revoked_at)
    end

    test "a well-formed id that matches nothing is the same 404", ctx do
      conn =
        bearer(ctx.owner_raw) |> delete("/w/#{ctx.ws.slug}/v1/chat-hosts/#{Ecto.UUID.generate()}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  test "a ChatHostsLive revoke with a malformed id shows an error and keeps the page", ctx do
    {:ok, view, _html} =
      scoped_conn()
      |> init_test_session(%{"api_token" => ctx.owner_raw})
      |> live("/w/#{ctx.ws.slug}/p/default/studio/chat-hosts")

    html = render_click(view, "revoke", %{"id" => "not-a-uuid"})

    assert html =~ "That machine is not enrolled in this workspace"
    assert Process.alive?(view.pid)
    assert [%{id: host_id}] = ChatHosts.list_hosts(ctx.ws.id)
    assert host_id == ctx.host_id
  end

  test "resolve/2 with a malformed host id is host_not_found", ctx do
    assert {:error, :host_not_found} = ChatHosts.resolve(ctx.ws.id, "not-a-uuid")
    assert is_nil(ChatHosts.get_host(ctx.ws.id, "not-a-uuid"))
  end

  describe "POST /v1/chat-host/events" do
    test "a malformed lease_id is the 422 lease_not_found a missing lease answers", ctx do
      for lease_id <- ["not-a-uuid", nil, 42, Ecto.UUID.generate()] do
        conn = post_event(ctx, %{lease_id: lease_id})

        error = json_response(conn, 422)["error"]

        assert {error["code"], error["message"]} == {"unprocessable", ":lease_not_found"},
               "lease_id #{inspect(lease_id)}"
      end
    end
  end

  describe "POST /v1/chat/sessions/:id/state" do
    test "a malformed session id is the 422 a session with no lease answers", ctx do
      for sid <- ["not-a-uuid", Ecto.UUID.generate()] do
        conn =
          host_conn(ctx)
          |> post("/v1/chat/sessions/#{sid}/state", Jason.encode!(%{state: "working", epoch: 1}))

        error = json_response(conn, 422)["error"]

        assert {error["code"], error["message"]} == {"unprocessable", ":lease_not_found"},
               "session id #{sid}"
      end
    end
  end

  defp post_event(ctx, attrs) do
    body =
      Map.merge(
        %{epoch: 1, cursor: 1, idempotency_key: "k-1", event: %{"kind" => "turn_started"}},
        attrs
      )

    host_conn(ctx) |> post("/v1/chat-host/events", Jason.encode!(body))
  end

  defp host_conn(ctx) do
    scoped_conn()
    |> put_req_header("authorization", "Host #{ctx.credential}")
    |> put_req_header("content-type", "application/json")
  end

  defp bearer(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end
end
