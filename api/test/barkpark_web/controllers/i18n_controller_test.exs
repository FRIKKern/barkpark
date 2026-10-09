defmodule BarkparkWeb.I18nControllerTest do
  @moduledoc """
  task-84fa11e11dacdc1b — barkpark-studio (github-81) ships a HAND-COPIED nb
  translation of the paper-canvas UI strings (259/269, already short) because
  it has no LiveView render to read `data-strings` off of. This route hands
  back the SAME map `BarkparkWeb.StudioLocale.component_strings(:paper_canvas)`
  stamps on `<bp-paper-canvas>` (`paper_editor.ex:956`), so any host fetches
  the real thing instead of maintaining a second copy.

  THE LOAD-BEARING ASSERTION (per the row's own criterion): the route's keys
  equal the stamped map's keys EXACTLY, not a subset. Calling
  `component_strings/1` directly makes this an identity, not a fixture copy
  that could silently diverge the moment someone edits one and not the other.
  """
  use BarkparkWeb.ConnCase, async: true

  alias BarkparkWeb.StudioLocale

  defp stamped_keys do
    :paper_canvas
    |> StudioLocale.component_strings()
    |> Jason.decode!()
    |> Map.keys()
    |> Enum.sort()
  end

  describe "GET /v1/i18n/paper_canvas" do
    test "with no ?locale, answers 200 in English with the SAME keys component_strings/1 stamps" do
      resp = build_conn() |> get("/v1/i18n/paper_canvas")
      body = json_response(resp, 200)

      assert body["locale"] == "en"
      assert is_map(body["strings"])
      assert Map.keys(body["strings"]) |> Enum.sort() == stamped_keys()
    end

    test "?locale=nb-NO answers in Norwegian, same keys, at least one translated value" do
      resp = build_conn() |> get("/v1/i18n/paper_canvas?locale=nb-NO")
      body = json_response(resp, 200)

      assert body["locale"] == "nb-NO"
      assert Map.keys(body["strings"]) |> Enum.sort() == stamped_keys()

      assert body["strings"]["Bold"] == "Fet",
             "expected a known nb_NO .po translation to come through, got #{inspect(body["strings"]["Bold"])}"
    end

    test "an unknown ?locale falls back to en rather than refusing" do
      resp = build_conn() |> get("/v1/i18n/paper_canvas?locale=xx-ZZ")
      body = json_response(resp, 200)

      assert body["locale"] == "en"
      assert body["strings"]["Bold"] == "Bold"
    end

    test "a bare 'nb' (not the known 'nb-NO' spelling) also falls back to en" do
      resp = build_conn() |> get("/v1/i18n/paper_canvas?locale=nb")
      assert json_response(resp, 200)["locale"] == "en"
    end

    test "is public -- no Authorization header required" do
      resp = build_conn() |> get("/v1/i18n/paper_canvas")
      assert resp.status == 200
    end
  end
end
