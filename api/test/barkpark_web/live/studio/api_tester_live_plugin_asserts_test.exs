defmodule BarkparkWeb.Studio.ApiTesterLivePluginAssertsTest do
  @moduledoc """
  Unit coverage for `ApiTesterLive.enrich_with_plugin_asserts/3` —
  the bridge that runs `Barkpark.ApiTestRunner.Asserts.evaluate/2`
  over a `Runner.run/2` result map and merges assert + cleanup data
  back into the result the response panel renders (task barkpark-jivi).

  The enrichment helper is the load-bearing logic. We unit-test it
  directly against synthetic Runner-result maps + plugin-spec maps —
  no live HTTP, no LiveView mount, no Bandit. `skip_cleanup: true`
  short-circuits the cleanup HTTP fan-out so the test stays pure.
  """

  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.ApiTesterLive

  # Synthetic shape matching what `Barkpark.ApiTester.Runner.run/2`
  # actually returns (status / headers / body_text / body_json /
  # duration_ms / verdict). Asserts.evaluate/2 reads body from :body —
  # the enrichment helper re-maps body_text → body for us.
  defp synth_result(body_text, status \\ 200) do
    %{
      status: status,
      headers: [{"content-type", "application/json"}],
      body_text: body_text,
      body_json:
        Jason.decode(body_text)
        |> case do
          {:ok, json} -> json
          _ -> nil
        end,
      duration_ms: 42,
      verdict: :pass,
      verdict_reason: "200 OK"
    }
  end

  describe "enrich_with_plugin_asserts/3 — happy path" do
    test "every passing assert lands in :plugin_asserts with status: :pass" do
      result = synth_result(~s|{"name":"book","ok":true}|)

      spec = %{
        name: "Book schema is exposed via /api/schemas",
        asserts: [
          {:status, 200},
          {:body_contains, ~s|"name":"book"|},
          {:duration_under_ms, 1_500}
        ]
      }

      enriched =
        ApiTesterLive.enrich_with_plugin_asserts(result, spec, skip_cleanup: true)

      assert enriched.plugin_status == :pass
      assert enriched.plugin_cleanup == []
      assert length(enriched.plugin_asserts) == 3

      assert Enum.all?(enriched.plugin_asserts, &(&1.status == :pass))

      # Each entry carries the original assertion tuple + a human message.
      tags = Enum.map(enriched.plugin_asserts, & &1.assertion)
      assert {:status, 200} in tags
      assert {:body_contains, ~s|"name":"book"|} in tags
      assert {:duration_under_ms, 1_500} in tags
    end

    test "preserves the original result fields (status, body_text, duration_ms)" do
      result = synth_result(~s|{"ok":true}|)
      spec = %{name: "x", asserts: [{:status, 200}]}

      enriched =
        ApiTesterLive.enrich_with_plugin_asserts(result, spec, skip_cleanup: true)

      assert enriched.status == 200
      assert enriched.body_text == ~s|{"ok":true}|
      assert enriched.duration_ms == 42
      assert enriched.verdict == :pass
    end
  end

  describe "enrich_with_plugin_asserts/3 — failing assert" do
    test "one failing assert flips :plugin_status to :fail" do
      result = synth_result(~s|{"name":"different"}|, 404)

      spec = %{
        name: "expects 200 but server says 404",
        asserts: [
          # this fails — server returned 404
          {:status, 200},
          # this passes — body does contain "name"
          {:body_contains, "name"}
        ]
      }

      enriched =
        ApiTesterLive.enrich_with_plugin_asserts(result, spec, skip_cleanup: true)

      assert enriched.plugin_status == :fail

      [first, second] = enriched.plugin_asserts
      assert first.status == :fail
      assert first.assertion == {:status, 200}
      assert first.message =~ "expected status 200, got 404"
      assert second.status == :pass
    end
  end

  describe "enrich_with_plugin_asserts/3 — assert-shape coverage" do
    test "no :asserts key in spec → empty list and :unverified status" do
      result = synth_result(~s|{}|)
      spec = %{name: "informational"}

      enriched =
        ApiTesterLive.enrich_with_plugin_asserts(result, spec, skip_cleanup: true)

      assert enriched.plugin_asserts == []
      # Empty assert list is :unverified (informational spec) — never a silent pass.
      assert enriched.plugin_status == :unverified
    end

    test "all eight built-in assert kinds dispatch through evaluate/2" do
      # One per shape — the bridge just delegates, this confirms the
      # tagged-tuple dispatch reaches Asserts.evaluate/2 for each.
      result = %{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body_text: ~s|{"keys":["a","b"],"deep":{"v":7}}|,
        body_json: %{"keys" => ["a", "b"], "deep" => %{"v" => 7}},
        duration_ms: 12,
        verdict: :pass,
        verdict_reason: "ok"
      }

      spec = %{
        name: "every shape",
        asserts: [
          {:status, 200},
          {:body_contains, "keys"},
          {:body_regex, ~r/deep/},
          {:json_path, ["deep", "v"], &(&1 == 7)},
          {:json_keys_include, ["keys", "deep"]},
          {:header, "content-type", "application/json"},
          :not_empty,
          {:duration_under_ms, 100}
        ]
      }

      enriched =
        ApiTesterLive.enrich_with_plugin_asserts(result, spec, skip_cleanup: true)

      assert enriched.plugin_status == :pass
      assert length(enriched.plugin_asserts) == 8
      assert Enum.all?(enriched.plugin_asserts, &(&1.status == :pass))
    end
  end

  describe "enrich_with_plugin_asserts/3 — cleanup gate" do
    test "skip_cleanup: true bypasses the cleanup HTTP fan-out" do
      result = synth_result(~s|{"ok":true}|)

      spec = %{
        name: "with cleanup",
        asserts: [{:status, 200}],
        cleanup: [
          %{
            method: :post,
            path: "/v1/data/mutate/production",
            auth: :admin,
            body: %{"mutations" => [%{"delete" => %{"id" => "probe", "type" => "book"}}]}
          }
        ]
      }

      enriched =
        ApiTesterLive.enrich_with_plugin_asserts(result, spec, skip_cleanup: true)

      assert enriched.plugin_cleanup == []
      assert enriched.plugin_status == :pass
    end
  end
end
