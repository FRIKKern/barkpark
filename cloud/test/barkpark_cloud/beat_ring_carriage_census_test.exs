defmodule BarkparkCloud.BeatRingCarriageCensusTest do
  @moduledoc """
  am-w2-per-class-carriage — THE TEETH. Every key the beat carries off the
  instance request-stats ring must reach an operator's EYE, and this census is
  what makes that a mechanism rather than a written finding.

  The epic's signature defect has now fired twice in the SAME seam, in both
  directions: `err_5xx_per_s` was extracted by the agent, decoded by the fleet
  row, and rendered by NOTHING on the console; `window_s` was decoded by the
  agent and thrown away at the control plane's door (dr-w14-bl). Both were
  found by a human reading code. A third would have been found the same way,
  because nothing checked.

  So the key set is DERIVED, never curated: it is parsed out of
  `internal/agent/report.go`'s own `reqStatsBody` decode struct — the single
  place the ring's wire shape is declared. Widen that struct and this census
  reds until the new key is carried the whole way. It cannot be satisfied by
  editing a list here, because there is no list here to edit.

  "Reaches an eye" is checked at three doors, and a key must pass all three:

    1. `Telemetry.normalize/1` READS it off the payload — decoded, not dropped.
    2. `Usage.compose/1` puts it in the envelope the console fetches.
    3. `app.js` RENDERS it, in one of the two shapes the meter model allows: a
       meter of its own (a `USAGE_METERS` spec) or the conditional qualifier
       that rides on a ring meter (`meter.<key>`) — the shape `window_s` and
       `err_5xx_per_s` both take, because neither is a signal an operator is
       asked to judge on its own.

  Door 3 is the one that matters and the one nothing enforced before: a key
  that clears doors 1 and 2 and fails door 3 is decoded-but-unrendered, which
  is precisely the state this row calls RED.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  @report_go Path.join(@repo_root, "internal/agent/report.go")
  @telemetry_ex Path.join(@repo_root, "cloud/lib/barkpark_cloud/telemetry.ex")
  @usage_ex Path.join(@repo_root, "cloud/lib/barkpark_cloud/usage.ex")
  @app_js Path.join(@repo_root, "cloud/priv/static/app.js")

  # Parse the json tags off `type reqStatsBody struct { … }`. This is the
  # instance RequestStats response shape as the agent itself declares it.
  defp ring_keys do
    src = File.read!(@report_go)

    [_, block] =
      Regex.run(~r/type reqStatsBody struct \{(.*?)\n\}/s, src) ||
        flunk("reqStatsBody struct not found in #{@report_go} — the census lost its anchor")

    Regex.scan(~r/`json:"([a-z0-9_]+)"`/, block) |> Enum.map(fn [_, k] -> k end)
  end

  # Door 1: read off the raw beat payload by the normalizer.
  defp decoded?(key, telemetry_src),
    do: String.contains?(telemetry_src, ~s|Map.get(payload, "#{key}")|)

  # Door 2: present in the console envelope composer.
  defp composed?(key, usage_src), do: String.contains?(usage_src, ":#{key}")

  # Door 3: rendered on the console — as a meter spec, or as the conditional
  # qualifier a ring meter carries.
  defp rendered?(key, app_src) do
    String.contains?(app_src, ~s|{ key: "#{key}"|) or String.contains?(app_src, "meter.#{key}")
  end

  defp doors(key, t, u, a), do: {decoded?(key, t), composed?(key, u), rendered?(key, a)}

  test "every request-stats ring key the beat carries is decoded, composed AND rendered" do
    keys = ring_keys()

    assert length(keys) >= 4,
           "parsed only #{length(keys)} json tag(s) off reqStatsBody — the parse broke, " <>
             "and a census that finds nothing passes everything"

    t = File.read!(@telemetry_ex)
    u = File.read!(@usage_ex)
    a = File.read!(@app_js)

    dead =
      for key <- keys,
          {d, c, r} = doors(key, t, u, a),
          not (d and c and r),
          do: {key, d, c, r}

    assert dead == [], """
    #{length(dead)} ring key(s) the beat carries do not reach an operator's eye.

    #{Enum.map_join(dead, "\n", fn {k, d, c, r} -> "  #{k}: decoded=#{d} composed=#{c} rendered=#{r}" end)}

    A key measured on the box, shipped over the wire and decoded here, then
    rendered by nothing, is the defect this row exists to end. Carry it:
    telemetry.ex normalize/1, usage.ex compose/1, and a render in app.js
    (a USAGE_METERS spec, or the ring qualifier).
    """
  end

  # THE CONTROL. The three predicates above are substring reads, and a
  # substring read that happens to match everything would print this census
  # GREEN while measuring nothing. These keys are NOT on the ring — a
  # plausible typo and a plausible-but-absent sibling — and each must fail at
  # door 3. If any of them "passes", the carriage assertion above is vacuous
  # and its green means nothing.
  test "CONTROL: a key the beat does not carry fails the render door" do
    a = File.read!(@app_js)
    u = File.read!(@usage_ex)

    for absent <- ["err_4xx_per_s", "req_per_h", "p99_ms", "windows_s"] do
      refute rendered?(absent, a),
             "#{absent} is not a ring key, yet the render predicate matched it — " <>
               "the predicate is too loose and the carriage test is vacuous"

      refute composed?(absent, u),
             "#{absent} is not a ring key, yet the compose predicate matched it"
    end
  end

  # Neither `window_s` nor `err_5xx_per_s` is a meter of its own (see Usage's
  # moduledoc): the window has no threshold and no bar, and the 5xx rate hangs
  # on the request-rate meter BECAUSE charter D103 forbids printing an error
  # rate apart from the volume that bounds it. This pins that shape, so a later
  # slice cannot "fix" a carriage red by promoting either to a meter — which
  # would also red the three-runtime `usage_meters.json` vocabulary fixture.
  test "the ring's context keys ride as qualifiers, never as meters of their own" do
    a = File.read!(@app_js)

    for key <- ["window_s", "err_5xx_per_s"] do
      refute String.contains?(a, ~s|{ key: "#{key}"|),
             "#{key} became a USAGE_METERS entry — it qualifies a meter, it is not one"

      assert String.contains?(a, "meter.#{key}"),
             "#{key} is not read by the meter renderer — the carriage broke again"
    end
  end
end
