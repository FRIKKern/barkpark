defmodule BarkparkWeb.Plugs.RequireChatAccessTest do
  @moduledoc """
  Unit coverage for `BarkparkWeb.Plugs.RequireChatAccess` scope resolution
  (Connectors charter D18/D19a/D21).

  These exercise the plug in isolation with `%Barkpark.Auth.ApiToken{}` struct
  literals assigned directly onto the conn — no DB, no `ConnCase`. This is the
  only way to cover the fail-closed `chat`-permissioned + `nil`-workspace deny
  branch (`require_chat_access.ex` `chat_scope/1`), because `Auth.create_token`
  cannot mint a token with `workspace_id: nil` and a `chat` permission, and
  `Auth.has_permission?/2` is pure list membership (`auth.ex:738`).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.Plugs.RequireChatAccess

  defp run(token) do
    conn(:get, "/v1/chat/sessions")
    |> assign(:api_token, token)
    |> RequireChatAccess.call(RequireChatAccess.init([]))
  end

  test "global admin token resolves to :global scope, not halted" do
    conn = run(%ApiToken{permissions: ["admin"], workspace_id: nil})

    refute conn.halted
    assert conn.assigns.chat_scope == :global
  end

  test "workspace-bound chat token resolves to {:workspace, id}, not halted" do
    ws = Ecto.UUID.generate()
    conn = run(%ApiToken{permissions: ["chat"], workspace_id: ws})

    refute conn.halted
    assert conn.assigns.chat_scope == {:workspace, ws}
  end

  test "chat-permissioned token with NO workspace binding is denied (403 forbidden)" do
    conn = run(%ApiToken{permissions: ["chat"], workspace_id: nil})

    assert conn.halted
    assert conn.status == 403
    assert %{"error" => %{"code" => "forbidden"}} = Jason.decode!(conn.resp_body)
    refute Map.has_key?(conn.assigns, :chat_scope)
  end

  test "token without the chat permission is denied (403 forbidden)" do
    conn = run(%ApiToken{permissions: ["read"], workspace_id: Ecto.UUID.generate()})

    assert conn.halted
    assert conn.status == 403
    assert %{"error" => %{"code" => "forbidden"}} = Jason.decode!(conn.resp_body)
    refute Map.has_key?(conn.assigns, :chat_scope)
  end
end
