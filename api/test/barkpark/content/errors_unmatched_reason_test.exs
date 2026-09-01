defmodule Barkpark.Content.ErrorsUnmatchedReasonTest do
  @moduledoc """
  The `Barkpark.Content.Errors.build/1` CATCH-ALL: an unanticipated reason term
  must be NAMED in the envelope and LOGGED on the server.

  WHY THIS SEAM AND NOT THE MUTATE DOOR. `BarkparkWeb.MutateController` declares
  `action_fallback BarkparkWeb.FallbackController` but does not route its
  `{:error, reason}` tuples through it — `respond_with_error/2` calls
  `Errors.to_envelope/2` directly, because it also owns the v2 validation-failed
  reshaping. So `to_envelope/2` IS the seam the write door actually crosses, and
  it is the seam pinned here. Two remedies for a nameless 500 already existed and
  the returned-tuple path routes around BOTH of them: the 2026-08-09 fault-family
  fix (#11364) lives in `BarkparkWeb.ErrorJSON`, which a RETURNED `{:error,
  term}` never reaches, and FallbackController's "NEVER SILENT ON 5xx" log fires
  only for controllers that delegate to it. Re-seating both here is what makes
  every caller of `to_envelope/2` — MutateController included — inherit them.

  RED-BEFORE (run in this worktree against the pre-change `defp build(_), do:
  %{code: "internal_error", message: "unknown error", status: 500}`):
  6 tests, 4 failures — the three naming tests on
  `left: "unknown error"` / `right: "unknown error ({:pool_exhausted, map})"`,
  and the log test on an empty capture. The two invariance tests (`code` stays
  byte-identical, `{:error, :unknown}` stays bare) passed BEFORE and AFTER by
  construction; they are the guard on the fix, not the proof of the defect.

  SCOPE NOTE (shared test database): every assertion here is a pure function
  call on a literal term. Nothing touches `Repo`, so no other agent's rows can
  reach it and no count here can be luck.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content.Errors

  setup do
    prev = Logger.metadata()
    on_exit(fn -> Logger.reset_metadata(prev) end)
    Logger.metadata(request_id: nil)
    :ok
  end

  # ── The envelope NAMES the shape ───────────────────────────────────────────

  test "a tagged-tuple reason no build/1 clause matches names its TAG in the message" do
    env =
      capture_and_envelope(fn ->
        Errors.to_envelope({:error, {:pool_exhausted, %{"queue" => "primary"}}})
      end)

    assert env.status == 500

    # ORDER IS LOAD-BEARING. The shape assertion is deliberately loose so the
    # LEAK GUARD below is the assertion that decides — an implementation that
    # started speaking the payload would otherwise abort on the exact-equality
    # line and the guard would never run (the lesson error_render_integration_
    # test.exs records for the crash path).
    assert env.message =~ ~r/\Aunknown error \(.+\)\z/
    refute env.message =~ "queue"
    refute env.message =~ "primary"
    assert env.message == "unknown error ({:pool_exhausted, map})"
  end

  test "a bare atom reason is spoken verbatim — it is what an operator routes on" do
    env = capture_and_envelope(fn -> Errors.to_envelope(:totally_unexpected) end)

    assert env.message == "unknown error (:totally_unexpected)"
  end

  test "a struct reason is named by its MODULE, never by its fields" do
    env =
      capture_and_envelope(fn ->
        Errors.to_envelope({:error, %ArgumentError{message: "boom — secret detail"}})
      end)

    assert env.message =~ ~r/\Aunknown error \(.+\)\z/
    refute env.message =~ "boom"
    refute env.message =~ "secret"
    assert env.message == "unknown error (%ArgumentError{})"
  end

  # ── The catch-all is NEVER SILENT ──────────────────────────────────────────

  test "an unmatched reason term emits an error log naming the descriptor" do
    # PRESENCE, never absence: this file is `async: false`, but capture_log is a
    # process-level handler either way and a refute-on-absence would be unsound
    # the moment anything else logs concurrently. Asserting the line IS there is
    # sound under any concurrency.
    log =
      capture_log(fn ->
        Errors.to_envelope({:error, {:pool_exhausted, %{"queue" => "primary"}}})
      end)

    assert log =~ "Barkpark.Content.Errors"
    assert log =~ "no build/1 clause matched"
    assert log =~ "{:pool_exhausted, map}"
    # The SERVER-SIDE log may carry the full term (FallbackController already
    # does exactly this, bounded); only the ENVELOPE is redacted.
    assert log =~ "pool_exhausted"
  end

  # ── The invariants the fix must not break ──────────────────────────────────

  test "the `code` stays byte-identical internal_error, with its registered hint" do
    env = capture_and_envelope(fn -> Errors.to_envelope({:error, {:whatever, 1}}) end)

    # BarkparkCloud.Sites.Deploy.transient_refusal?/1 grants its retry grace by
    # matching this CODE, never the message. Moving the code turns that grace
    # terminal (stated in error_json.ex) — only the message may change.
    assert env.code == "internal_error"
    assert env.status == 500
    assert is_binary(env.hint) and env.hint != ""
    assert MapSet.member?(Errors.known_codes(), "internal_error")
  end

  test "the {:error, :unknown} sentinel still reads exactly `unknown error`" do
    # BarkparkWeb.ErrorJSON renders this when RenderErrors hands it a 500 with no
    # :kind/:reason at all — there is genuinely nothing to name, and its moduledoc
    # promises this exact string. Narrowing it out of the catch-all is what lets
    # the catch-all log without turning a fault-free render into noise.
    env = Errors.to_envelope({:error, :unknown})

    assert env.code == "internal_error"
    assert env.message == "unknown error"
    assert env.status == 500
  end

  # Swallow the (intended) catch-all log so the suite output stays readable,
  # and hand back the envelope the call produced.
  defp capture_and_envelope(fun) do
    {env, _log} = with_log(fun)
    env
  end
end
