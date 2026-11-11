defmodule BarkparkWeb.ChatHostEnrollRefusalTest do
  @moduledoc """
  A VALID enrollment token whose request fails validation used to get the same
  401 `invalid_enrollment` as a wrong token (task-c02eefeb0ed7381c). The Go
  client maps 401 to "chat host credential revoked", so a capabilities shape
  the server refused looked exactly like a dead token, and nothing on the
  server said otherwise.

  Now a valid token with a refused changeset answers 422 with the field errors
  and logs them, and the token stays unused so a fixed host can retry. A wrong
  token still gets the one 401, so an anonymous caller learns nothing new: only
  the holder of a valid token can reach the 422, and a 201 would tell them the
  same thing.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the /v1/chat-host routes.
  @moduletag :requires_plugins

  import ExUnit.CaptureLog

  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy

  @refused_caps %{"protocol_version" => 1, "providers" => %{}, "token" => "sk-not-allowed"}

  defp issue_token do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "cer-#{suffix}", name: "CER #{suffix}"})
    {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: "daemon"})
    token
  end

  defp enroll(body) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/chat-host/enroll", Jason.encode!(body))
  end

  test "a valid token with refused capabilities is 422 naming the field, and is logged without the token" do
    token = issue_token()

    log =
      capture_log(fn ->
        conn = enroll(%{"enrollment_token" => token, "capabilities" => @refused_caps})

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(conn, 422)

        assert fields["capabilities"] == ["must contain only non-secret readiness metadata"]
      end)

    assert log =~ "chat host enrollment refused"
    assert log =~ "must contain only non-secret readiness metadata"
    refute log =~ token
    refute log =~ "sk-not-allowed"
  end

  test "the refused attempt leaves the token unused, so a fixed host can retry" do
    token = issue_token()

    capture_log(fn ->
      assert enroll(%{"enrollment_token" => token, "capabilities" => @refused_caps}).status ==
               422
    end)

    conn = enroll(%{"enrollment_token" => token, "protocol_version" => 1})
    assert is_binary(json_response(conn, 201)["credential"])
  end

  test "a wrong token with the same refused capabilities is still the one 401" do
    conn =
      enroll(%{"enrollment_token" => "not-a-real-token", "capabilities" => @refused_caps})

    assert %{"error" => %{"code" => "invalid_enrollment"}} = json_response(conn, 401)
  end

  test "a used token is still the one 401" do
    token = issue_token()
    assert enroll(%{"enrollment_token" => token}).status == 201

    conn = enroll(%{"enrollment_token" => token, "capabilities" => @refused_caps})
    assert %{"error" => %{"code" => "invalid_enrollment"}} = json_response(conn, 401)
  end
end
