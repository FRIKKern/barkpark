defmodule BarkparkWeb.Plugs.RequireMediaProcessingCallbackTokenTest do
  @moduledoc """
  Unit tests for the media-processing callback auth plug.

  THREAT: `POST /v1/media/:dataset/processing/:id/callback` mutates media
  processing state from an EXTERNAL processor, and this plug is its SOLE auth.
  A bypass lets anyone forge processing-complete callbacks.

  The neighboring integration test only covers the MISSING-token path (no
  `authorization` header fails the `["Bearer " <> presented]` list-match and
  never reaches `Plug.Crypto.secure_compare/2`). These tests cover the
  present-but-WRONG-token branch — the `secure_compare` decision — from both
  directions so the assertions distinguish a right token from a wrong one.

  Pure-unit: builds a bare `Plug.Test.conn/2` and calls the plug directly.
  No DataCase / DB / full boot. The expected token comes from
  config/test.exs (`:media_processing_callback_token`).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkWeb.Plugs.RequireMediaProcessingCallbackToken, as: Plug

  # config/test.exs sets this fixed value.
  @valid_token "test-media-processing-callback-token"

  defp call(bearer) do
    conn(:post, "/v1/media/production/processing/abc/callback", %{"status" => "ready"})
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> Plug.call(Plug.init([]))
  end

  describe "wrong-token branch (secure_compare)" do
    test "a present-but-WRONG bearer token is rejected: 401 + halted" do
      conn = call("wrong-token")

      # This is the branch the missing-token test never reaches: the header
      # matches `Bearer <token>`, so `secure_compare/2` runs and must fail.
      assert conn.status == 401
      assert conn.halted
    end

    test "the 401 carries the unauthorized envelope" do
      conn = call("wrong-token")
      assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "correct-token positive control (both directions)" do
    test "the correct env token passes the plug: not halted" do
      conn = call(@valid_token)

      # Proves the wrong-token test isn't vacuous ("any token 401s"): the
      # matching token clears secure_compare and the plug lets the conn through.
      refute conn.halted
      refute conn.status == 401
    end
  end
end
