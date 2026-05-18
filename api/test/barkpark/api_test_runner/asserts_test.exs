defmodule Barkpark.ApiTestRunner.AssertsTest do
  @moduledoc """
  Per-tag unit coverage for the 8 built-in evaluators in
  `Barkpark.ApiTestRunner.Asserts.evaluate/2` (plan §0 Q2, Goal
  `barkpark-bsp`). Each tag gets at least one passing case and one
  failing case — 16 functional cases plus a handful of edge cases
  (nil body, malformed JSON, unknown tag, header-as-fn predicate).

  Tests treat the module as a black box: we only assert on the
  `{:pass | :fail, message}` tuple returned by `evaluate/2`, never on
  internal helpers — keeps the suite resilient to internal refactors.
  Safe to run `async: true` since `Asserts` is a pure module.
  """

  use ExUnit.Case, async: true

  alias Barkpark.ApiTestRunner.Asserts

  # ── Shared response fixtures ────────────────────────────────────────

  @body_ok ~s|{"count":3,"items":[{"id":"x"}],"meta":{"v":"1"}}|
  @resp %{
    status: 200,
    body: @body_ok,
    headers: [{"content-type", "application/json"}, {"x-request-id", "abc-123"}],
    duration_ms: 50
  }

  @resp_500 %{@resp | status: 500}
  @resp_empty %{@resp | body: ""}
  @resp_nil_body %{@resp | body: nil}
  @resp_bad_json %{@resp | body: "{not json}"}
  @resp_slow %{@resp | duration_ms: 9_999}

  # ── {:status, integer} ──────────────────────────────────────────────

  describe "{:status, n}" do
    test "passes when status matches" do
      assert {:pass, msg} = Asserts.evaluate({:status, 200}, @resp)
      assert msg =~ "200"
    end

    test "fails when status differs" do
      assert {:fail, msg} = Asserts.evaluate({:status, 200}, @resp_500)
      assert msg =~ "200"
      assert msg =~ "500"
    end
  end

  # ── {:body_contains, str} ───────────────────────────────────────────

  describe "{:body_contains, needle}" do
    test "passes when needle appears in body" do
      assert {:pass, _} = Asserts.evaluate({:body_contains, ~s|"count":3|}, @resp)
    end

    test "fails when needle does not appear in body" do
      assert {:fail, msg} = Asserts.evaluate({:body_contains, "needle-not-here"}, @resp)
      assert msg =~ "needle-not-here"
    end

    test "fails when body is nil" do
      assert {:fail, msg} = Asserts.evaluate({:body_contains, "x"}, @resp_nil_body)
      assert msg =~ "nil"
    end
  end

  # ── {:body_regex, regex} ────────────────────────────────────────────

  describe "{:body_regex, re}" do
    test "passes when the regex matches" do
      assert {:pass, _} = Asserts.evaluate({:body_regex, ~r/"count":\d+/}, @resp)
    end

    test "fails when the regex does not match" do
      assert {:fail, _} = Asserts.evaluate({:body_regex, ~r/wont-match/}, @resp)
    end
  end

  # ── {:json_path, path, fun} ─────────────────────────────────────────

  describe "{:json_path, path, fun}" do
    test "passes when predicate returns true at the path" do
      assert {:pass, _} =
               Asserts.evaluate({:json_path, ["count"], fn n -> n == 3 end}, @resp)
    end

    test "fails when predicate returns false at the path" do
      assert {:fail, msg} =
               Asserts.evaluate({:json_path, ["count"], fn n -> n == 99 end}, @resp)

      assert msg =~ "count"
    end

    test "fails when the path is missing from the body" do
      assert {:fail, msg} =
               Asserts.evaluate({:json_path, ["nope"], fn _ -> true end}, @resp)

      assert msg =~ "nope"
    end

    test "fails when the body is not valid JSON" do
      assert {:fail, msg} =
               Asserts.evaluate({:json_path, ["count"], fn _ -> true end}, @resp_bad_json)

      assert msg =~ "decode"
    end

    test "supports list-index traversal" do
      assert {:pass, _} =
               Asserts.evaluate(
                 {:json_path, ["items", 0, "id"], fn v -> v == "x" end},
                 @resp
               )
    end
  end

  # ── {:json_keys_include, [keys]} ────────────────────────────────────

  describe "{:json_keys_include, keys}" do
    test "passes when every requested key is present at top level" do
      assert {:pass, _} =
               Asserts.evaluate({:json_keys_include, ["count", "items"]}, @resp)
    end

    test "fails when at least one requested key is missing" do
      assert {:fail, msg} =
               Asserts.evaluate({:json_keys_include, ["count", "missing_key"]}, @resp)

      assert msg =~ "missing_key"
    end
  end

  # ── {:header, name, val_or_fn} ──────────────────────────────────────

  describe "{:header, name, expected}" do
    test "passes when string value matches the response header" do
      assert {:pass, _} = Asserts.evaluate({:header, "content-type", "application/json"}, @resp)
    end

    test "fails when string value differs" do
      assert {:fail, _} = Asserts.evaluate({:header, "content-type", "text/plain"}, @resp)
    end

    test "fails when the header is absent" do
      assert {:fail, msg} = Asserts.evaluate({:header, "x-missing", "anything"}, @resp)
      assert msg =~ "x-missing"
    end

    test "supports 1-arity predicate as expected value (pass)" do
      assert {:pass, _} =
               Asserts.evaluate(
                 {:header, "x-request-id", fn v -> String.starts_with?(v, "abc-") end},
                 @resp
               )
    end

    test "supports 1-arity predicate as expected value (fail)" do
      assert {:fail, _} =
               Asserts.evaluate(
                 {:header, "x-request-id", fn v -> String.starts_with?(v, "zzz-") end},
                 @resp
               )
    end
  end

  # ── :not_empty ──────────────────────────────────────────────────────

  describe ":not_empty" do
    test "passes when the body has content" do
      assert {:pass, _} = Asserts.evaluate(:not_empty, @resp)
    end

    test "fails when the body is empty string" do
      assert {:fail, _} = Asserts.evaluate(:not_empty, @resp_empty)
    end

    test "fails when the body is nil" do
      assert {:fail, _} = Asserts.evaluate(:not_empty, @resp_nil_body)
    end
  end

  # ── {:duration_under_ms, ceiling} ───────────────────────────────────

  describe "{:duration_under_ms, n}" do
    test "passes when duration is within ceiling" do
      assert {:pass, _} = Asserts.evaluate({:duration_under_ms, 500}, @resp)
    end

    test "fails when duration exceeds ceiling" do
      assert {:fail, msg} = Asserts.evaluate({:duration_under_ms, 500}, @resp_slow)
      assert msg =~ "9999"
    end
  end

  # ── unknown tag ─────────────────────────────────────────────────────

  describe "unknown assert tag" do
    test "fails with a descriptive message rather than raising" do
      assert {:fail, msg} = Asserts.evaluate({:bogus_tag, 1, 2}, @resp)
      assert msg =~ "bogus_tag"
    end
  end
end
