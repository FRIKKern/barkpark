defmodule BarkparkWeb.ConnCaseRecycleScopedTest do
  @moduledoc """
  task-696e001dce483d37 — THE MECHANISM BEHIND THE FLAKE.

  `PreviewTokenDocScopeTest` "backlinks, related, tags and ?expand are
  refused" got a 429 under suite load (PR #22401, run 37917883290). The PR it
  landed on touched neither preview routes nor rate limiting — the test loops
  4 requests through one `conn` via `Phoenix.ConnTest.recycle/1`, and
  `recycle/1` rebuilds the conn via `build_conn/0` under the hood, copying
  over only host/peer/cookies/named-headers — NOT `conn.private`. So a
  `scoped_conn()`'s `:barkpark_rate_limit_scope` is silently DROPPED on
  recycle, the request falls back to the UNSCOPED client-IP bucket
  (`ip:127.0.0.1` in test), and that bucket is shared by every other
  anonymous/preview request in the whole async suite — the exact failure mode
  `BarkparkWeb.ConnCase.scoped_conn/0`'s own moduledoc describes for a bare
  `build_conn()`, reached here through an indirect path.

  THE GAP IN THE EXISTING GUARD: `RateLimitTestConnScopeTest` greps source
  text for the literal token `build_conn()`. `recycle()` never writes that
  token at a call site, so this shape is invisible to it — confirmed by this
  file's own census below.

  Reproducing suite-load concurrency deterministically in one test run isn't
  possible (the flake needs OTHER test processes sharing the same bucket at
  the same moment); what IS deterministic, and what this file pins, is the
  MECHANISM: whether the scope survives the recycle. That is the one fact the
  409/429 distinction actually turns on.
  """
  use BarkparkWeb.ConnCase, async: true

  describe "THE BUG: a bare recycle() silently drops the rate-limit test scope" do
    test "scoped_conn() carries the scope; a bare recycle() of it does not" do
      conn = scoped_conn()
      assert conn.private[:barkpark_rate_limit_scope], "scoped_conn/0 itself must stamp it"

      recycled = recycle(conn)

      refute recycled.private[:barkpark_rate_limit_scope],
             "THE BUG, reproduced: Phoenix.ConnTest.recycle/1 rebuilds the conn via " <>
               "build_conn/0 and does not copy `private` — if this ever starts passing, " <>
               "recycle/1's contract changed and recycle_scoped/1 may no longer be needed, " <>
               "but should still be harmless"
    end
  end

  describe "THE FIX: recycle_scoped/1 re-stamps the SAME per-test-process scope" do
    test "survives the recycle, and names the identical scope the original conn had" do
      conn = scoped_conn()
      original_scope = conn.private[:barkpark_rate_limit_scope]

      recycled = recycle_scoped(conn)

      assert recycled.private[:barkpark_rate_limit_scope] == original_scope,
             "recycle_scoped/1 must re-apply THIS test process's own scope — a different " <>
               "scope would still isolate the bucket from the suite, but a nil one (the bug) " <>
               "or another test's scope would not"
    end

    test "a chain of several recycle_scoped/1 calls keeps the SAME scope throughout" do
      conn = scoped_conn()
      scope = conn.private[:barkpark_rate_limit_scope]

      final =
        conn
        |> recycle_scoped()
        |> recycle_scoped()
        |> recycle_scoped()

      assert final.private[:barkpark_rate_limit_scope] == scope
    end
  end

  describe "THE GAP: the existing scanner cannot see this shape" do
    test "RateLimitTestConnScopeTest's literal build_conn() regex does not match recycle()" do
      refute Regex.match?(~r/(?<![\w.])build_conn\(\)/, "conn |> recycle() |> get(path)"),
             "if this ever matches, the scanner's own regex changed and may now catch " <>
               "recycle() too -- re-check whether this file (and the fix it documents) " <>
               "is still needed"
    end
  end
end
