defmodule BarkparkWeb.ChatHostEnrollTypeTest do
  @moduledoc """
  POST /v1/chat-host/enroll is FULLY ANONYMOUS (the router's first
  `scope "/v1/chat-host"` block pipes it through `:api` alone — enrollment
  authenticates by POSSESSION of the token),
  so every arm of it is reachable with no credential at all.

  The controller's first `enroll/2` clause used to match on key PRESENCE while
  the context clause (`Barkpark.ChatHosts.enroll/2`) guards `is_binary/1`. A
  present-but-non-binary `enrollment_token` therefore slipped past the
  controller and blew the context guard with a FunctionClauseError — a 500 an
  anonymous caller could trigger with `?enrollment_token[]=x`. Nothing
  downgraded it: `BarkparkWeb.controller/0` declares no action_fallback, and
  Phoenix only maps `Phoenix.ActionClauseError` (a clause error on the ACTION)
  to 400 — this raised inside a different module.

  A wrong-TYPE token must land on the SAME clean 401 the absent-key arm
  already returns.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy

  # No token, no session — exactly what an unauthenticated caller sends.
  defp anon, do: build_conn()

  defp assert_invalid_enrollment(conn) do
    assert conn.status == 401
    assert %{"error" => %{"code" => "invalid_enrollment"}} = json_response(conn, 401)
    conn
  end

  describe "anonymous POST /v1/chat-host/enroll with a non-binary token" do
    test "a list-valued token (?enrollment_token[]=x) is 401, not 500" do
      anon()
      |> post("/v1/chat-host/enroll?enrollment_token[]=x")
      |> assert_invalid_enrollment()
    end

    test "an integer-valued token in a JSON body is 401, not 500" do
      anon()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat-host/enroll", Jason.encode!(%{"enrollment_token" => 123}))
      |> assert_invalid_enrollment()
    end

    test "a map-valued token (?enrollment_token[k]=v) is 401, not 500" do
      anon()
      |> post("/v1/chat-host/enroll?enrollment_token[k]=v")
      |> assert_invalid_enrollment()
    end

    test "a null-valued token in a JSON body is 401, not 500" do
      anon()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat-host/enroll", Jason.encode!(%{"enrollment_token" => nil}))
      |> assert_invalid_enrollment()
    end
  end

  describe "the arms the guard must not disturb" do
    # The author's own catch-all: ABSENT key. This was already 401 before the
    # fix — it is here so a regression that swallows the whole action is visible.
    test "an absent token is still 401" do
      anon()
      |> post("/v1/chat-host/enroll", %{})
      |> assert_invalid_enrollment()
    end

    test "a present-but-wrong binary token is still 401" do
      anon()
      |> post("/v1/chat-host/enroll", %{"enrollment_token" => "nope-not-a-real-token"})
      |> assert_invalid_enrollment()
    end

    # POSITIVE CONTROL: a real, unexpired enrollment token still enrolls. Proves
    # the guard narrowed the clause to non-binaries and nothing else.
    test "a valid binary token still enrolls (201)" do
      suffix = System.unique_integer([:positive])
      {:ok, ws} = Tenancy.create_workspace(%{slug: "ce-#{suffix}", name: "CE #{suffix}"})
      {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: "daemon"})

      conn = post(anon(), "/v1/chat-host/enroll", %{"enrollment_token" => token})

      assert conn.status == 201
      body = json_response(conn, 201)
      assert is_binary(body["credential"])
      assert body["host"]["name"] == "daemon"
    end
  end
end
