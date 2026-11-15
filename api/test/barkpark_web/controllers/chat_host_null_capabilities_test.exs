defmodule BarkparkWeb.ChatHostNullCapabilitiesTest do
  @moduledoc """
  A heartbeat or an enrollment that sends `capabilities: null` (or
  `protocol_version: null`) answers a typed 422 and stores nothing
  (task-2cd727c3405afd23).

  `ChatHosts.heartbeat/2` and `complete_enrollment/3` read the body with
  `value(attrs, key, stored)`, which returns the stored value only when the key
  is ABSENT. A key present with JSON null came through as `nil`. Ecto's
  `validate_change/3` and `validate_number/3` skip a nil change, so the
  changeset was valid, and the NOT NULL columns
  (`20260714150000_create_registered_chat_hosts.exs`) raised a Postgrex
  not_null_violation: a 500 from the host's own credential. Found as probe R3
  in the review of PR #26484.

  The other wrong shapes (a string, a list, a number, `providers: null`) were
  already 422s. They are pinned here beside it so the refusal stays one
  contract: every one leaves the stored row as it was.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns /v1/chat-host.
  @moduletag :requires_plugins

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @caps %{
    "protocol_version" => 1,
    "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
  }

  # Each body is refused, and the field named is the one the 422 reports.
  @refused [
    {"capabilities null", %{"capabilities" => nil}, "capabilities"},
    {"capabilities a string", %{"capabilities" => "all"}, "capabilities"},
    {"capabilities a list", %{"capabilities" => ["claude"]}, "capabilities"},
    {"capabilities a number", %{"capabilities" => 7}, "capabilities"},
    {"providers null", %{"capabilities" => %{"protocol_version" => 1, "providers" => nil}},
     "capabilities"},
    {"protocol_version null", %{"protocol_version" => nil}, "protocol_version"}
  ]

  defp issue(ws) do
    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "null-#{System.unique_integer([:positive])}",
        capabilities: @caps
      })

    issued
  end

  defp workspace do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "hcn-#{suffix}", name: "HCN #{suffix}"})
    ws
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp stored(id) do
    row = Repo.get!(RegisteredHost, id)

    Map.take(row, [
      :capabilities,
      :protocol_version,
      :last_seen_at,
      :enrolled_at,
      :credential_hash
    ])
  end

  describe "ChatHosts.heartbeat/2" do
    test "capabilities nil is an {:error, changeset} on capabilities, not a raise" do
      issued = issue(workspace())
      {:ok, _} = ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})
      host = Repo.get!(RegisteredHost, issued.host.id)

      assert {:error, %Ecto.Changeset{} = changeset} =
               ChatHosts.heartbeat(host, %{"protocol_version" => 1, "capabilities" => nil})

      assert Keyword.has_key?(changeset.errors, :capabilities)
      assert Repo.get!(RegisteredHost, host.id).capabilities == @caps
    end
  end

  describe "POST /v1/chat-host/heartbeat" do
    for {label, body, field} <- @refused do
      test "#{label} answers 422 on #{field} and changes nothing", %{conn: conn} do
        issued = issue(workspace())

        {:ok, %{credential: credential}} =
          ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})

        before = stored(issued.host.id)

        resp =
          conn
          |> put_req_header("authorization", "Host #{credential}")
          |> post_json(
            "/v1/chat-host/heartbeat",
            Map.merge(%{"protocol_version" => 1}, unquote(Macro.escape(body)))
          )

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert Map.has_key?(fields, unquote(field))
        assert stored(issued.host.id) == before
        assert before.capabilities == @caps
      end
    end

    test "an omitted capabilities key keeps the stored map", %{conn: conn} do
      issued = issue(workspace())

      {:ok, %{credential: credential}} =
        ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})

      resp =
        conn
        |> put_req_header("authorization", "Host #{credential}")
        |> post_json("/v1/chat-host/heartbeat", %{"protocol_version" => 1})

      assert json_response(resp, 200)
      assert stored(issued.host.id).capabilities == @caps
    end
  end

  describe "POST /v1/chat-host/enroll" do
    for {label, body, field} <- @refused do
      test "#{label} answers 422 on #{field}, enrolls nothing, and leaves the token usable",
           %{conn: conn} do
        issued = issue(workspace())
        before = stored(issued.host.id)

        resp =
          post_json(
            conn,
            "/v1/chat-host/enroll",
            Map.merge(
              %{"enrollment_token" => issued.enrollment_token},
              unquote(Macro.escape(body))
            )
          )

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert Map.has_key?(fields, unquote(field))
        assert stored(issued.host.id) == before
        assert before.enrolled_at == nil

        # The transaction rolled back: the same token still enrolls.
        assert {:ok, %{credential: _}} =
                 ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})
      end
    end
  end
end
