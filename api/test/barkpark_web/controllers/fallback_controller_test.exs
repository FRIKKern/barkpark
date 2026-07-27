defmodule BarkparkWeb.FallbackControllerTest do
  @moduledoc """
  task-96d8ab2b582818a4 — the never-silent 5xx wall.

  The FallbackController's catch-all (`Errors.build/1`'s `build(_)`) maps any
  unrecognized `{:error, term}` to a 500 `internal_error`, and until this task
  it rendered that with ZERO log output — the exact silent shape of the round-3
  live import failure ("Sent 500" in the box journal, no error line, a
  request_id resolving to nothing). These tests pin BOTH halves of the fix:
  an unmatched term still renders the canonical envelope, AND the term is now
  logged at error level before the response goes out. A 4xx keeps rendering
  WITHOUT the error-level noise (it is not a server defect).
  """
  use BarkparkWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias BarkparkWeb.FallbackController

  test "an unmatched {:error, term} renders 500 internal_error AND logs the term", %{conn: conn} do
    {resp, log} =
      with_log(fn ->
        FallbackController.call(conn, {:error, {:mystery, :engine_term}})
      end)

    assert resp.status == 500
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "internal_error"

    assert log =~ "[error]"
    assert log =~ "FallbackController: rendering 500 internal_error"
    assert log =~ "{:mystery, :engine_term}"
  end

  test "{:error, :rollback} — Ecto's nested-rollback commit downgrade — is named in the log",
       %{conn: conn} do
    {resp, log} =
      with_log(fn ->
        FallbackController.call(conn, {:error, :rollback})
      end)

    assert resp.status == 500
    assert log =~ ":rollback"
  end

  test "a 4xx term renders WITHOUT error-level logging (not a server defect)", %{conn: conn} do
    {resp, log} =
      with_log(fn ->
        FallbackController.call(conn, {:error, :not_found})
      end)

    assert resp.status == 404
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    refute log =~ "FallbackController: rendering"
  end
end
