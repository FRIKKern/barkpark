defmodule Barkpark.Net.RetrySafetyTest do
  use ExUnit.Case, async: true

  alias Barkpark.Net.RetrySafety

  describe "replay_safe?/2" do
    test "idempotent methods replay" do
      for m <- [:get, :head, :options, :put, :delete] do
        assert RetrySafety.replay_safe?(m), "expected #{m} to be replay-safe"
      end
    end

    test "POST and PATCH do not replay" do
      refute RetrySafety.replay_safe?(:post)
      refute RetrySafety.replay_safe?(:patch)
    end

    test "an explicit :idempotent opt overrides the method in both directions" do
      assert RetrySafety.replay_safe?(:post, idempotent: true)
      refute RetrySafety.replay_safe?(:get, idempotent: false)
    end
  end

  describe "retry_after_transport_error?/3" do
    test ":timeout does NOT replay a POST — the write may already have landed" do
      refute RetrySafety.retry_after_transport_error?(:post, :timeout)
      refute RetrySafety.retry_after_transport_error?(:patch, :timeout)
    end

    test ":timeout still replays a GET" do
      assert RetrySafety.retry_after_transport_error?(:get, :timeout)
    end

    test "connect-stage failures replay ANY method — nothing was sent" do
      for reason <- [:econnrefused, :nxdomain, :ehostunreach, :enetunreach] do
        assert RetrySafety.retry_after_transport_error?(:post, reason),
               "expected #{reason} to be replayable for POST"
      end
    end

    test ":closed and :econnreset are post-write ambiguous and do NOT replay a POST" do
      refute RetrySafety.retry_after_transport_error?(:post, :closed)
      refute RetrySafety.retry_after_transport_error?(:post, :econnreset)
    end
  end

  describe "retry_after_status?/3" do
    test "502/504 do not replay a POST" do
      refute RetrySafety.retry_after_status?(:post, 502)
      refute RetrySafety.retry_after_status?(:post, 504)
    end

    test "502/504 still replay a GET" do
      assert RetrySafety.retry_after_status?(:get, 502)
      assert RetrySafety.retry_after_status?(:get, 504)
    end

    test "origin-authored 500/503 replay any method" do
      for status <- [500, 503] do
        assert RetrySafety.retry_after_status?(:post, status)
      end
    end
  end

  # The two clients are near-identical twins. The campaign rule: two copies of
  # one behaviour with no shared fixture is UNLOCKED, not covered twice. They
  # share THIS predicate — this pins that they still route through it, so a
  # future edit that re-inlines the decision in one client fails here rather
  # than diverging silently in production.
  describe "both HTTP clients route their retry decision through this module" do
    @clients [
      "lib/barkpark/plugins/onixedit/bokbasen/client.ex",
      "lib/barkpark/plugins/github/client.ex"
    ]

    test "each client calls retry_after_transport_error? and retry_after_status?" do
      for path <- @clients do
        src = File.read!(Path.join(File.cwd!(), path))

        assert src =~ "RetrySafety.retry_after_transport_error?",
               "#{path} no longer guards its transport-error retry arm"

        assert src =~ "RetrySafety.retry_after_status?",
               "#{path} no longer guards its 5xx retry arm"
      end
    end
  end
end
