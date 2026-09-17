defmodule BarkparkWeb.WebhookProbeScheduleRenderTest do
  @moduledoc """
  The auto-disable latch has an automatic exit — a half-open probe on a doubling
  cooldown (`Barkpark.Webhooks.next_probe_at/1`) — but the HTTP read path used
  to render only `auto_disabled_at` and `disable_reason`. An operator triaging
  "our webhooks stopped" saw a dead endpoint where the system saw a scheduled
  retry, and clicked re-enable by hand: the exact human-only exit the latch
  exists to remove. The inverse error was just as available — assuming a retry
  was imminent when the backoff had walked out to the 1h cap.

  These tests pin the SURFACE: that `GET /v1/webhooks/:dataset/:id` renders the
  probe schedule, that it is nil for an endpoint a PERSON disabled (only the
  automatic latch has an automatic exit), and that it moves OUTWARD after a
  failed probe so the walk to the cap is visible.

  Filed as `task-9f54bb0b94282e53`.
  """
  # async: false — sets the app-wide auto-disable threshold.
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Webhook

  @threshold 2

  setup do
    {:ok, _} = Auth.create_token("probe-render-admin", "dev", "test", ["read", "write", "admin"])

    prev = Application.get_env(:barkpark, :webhook_auto_disable_threshold)
    Application.put_env(:barkpark, :webhook_auto_disable_threshold, @threshold)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:barkpark, :webhook_auto_disable_threshold),
        else: Application.put_env(:barkpark, :webhook_auto_disable_threshold, prev)
    end)

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer probe-render-admin")
    |> put_req_header("content-type", "application/json")
  end

  # Create through the admin POST route so the row carries the conn's scope.
  defp make_webhook(conn, name) do
    body =
      Jason.encode!(%{
        "name" => name,
        "url" => "http://example.test/hook",
        "events" => ["patch"],
        "secret" => "s0"
      })

    resp = conn |> authed() |> post("/v1/webhooks/test", body)
    assert resp.status == 201
    id = Jason.decode!(resp.resp_body)["webhook"]["id"]
    Repo.get!(Webhook, id)
  end

  # Drive the streak past the threshold the way the dispatcher does.
  defp latch(%Webhook{id: id}) do
    capture_log([level: :info], fn ->
      Enum.each(1..@threshold, fn _ -> Webhooks.record_endpoint_failure(id, "http 500") end)
    end)
  end

  defp show(conn, %Webhook{id: id}) do
    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    assert resp.status == 200
    Jason.decode!(resp.resp_body)["webhook"]
  end

  describe "the probe schedule reaches the HTTP read path" do
    test "an auto-disabled endpoint renders a non-null next probe time and dark interval",
         %{conn: conn} do
      wh = make_webhook(conn, "Auto-latched")
      latch(wh)

      rendered = show(conn, wh)

      # Keys must be PRESENT at all — the whole defect was their absence.
      assert Map.has_key?(rendered, "next_probe_at"),
             "the operator has no way to see the automatic exit exists"

      assert Map.has_key?(rendered, "dark_for_seconds")

      assert rendered["auto_disabled_at"] != nil, "precondition: the latch actually fired"

      refute is_nil(rendered["next_probe_at"]),
             "a latched endpoint HAS a scheduled probe; rendering nil says it is permanently dead"

      refute is_nil(rendered["dark_for_seconds"])

      # It is the real schedule, not a constant: it agrees with the domain
      # function, and it is in the FUTURE relative to the disable stamp.
      {:ok, rendered_at, _} = DateTime.from_iso8601(rendered["next_probe_at"])
      reloaded = Repo.get!(Webhook, wh.id)

      assert DateTime.compare(
               DateTime.truncate(rendered_at, :second),
               DateTime.truncate(Webhooks.next_probe_at(reloaded), :second)
             ) == :eq

      assert DateTime.compare(rendered_at, reloaded.auto_disabled_at) == :gt
      assert rendered["dark_for_seconds"] >= 0
    end

    test "an endpoint a PERSON disabled renders nil for both — no automatic exit",
         %{conn: conn} do
      wh = make_webhook(conn, "Hand-disabled")

      resp =
        conn
        |> authed()
        |> put("/v1/webhooks/test/#{wh.id}", Jason.encode!(%{"active" => false}))

      assert resp.status == 200

      rendered = show(conn, wh)

      assert rendered["active"] == false, "precondition: the endpoint really is off"

      # `nil` and ABSENT both decode to nil, so pin presence first: without this
      # a payload that renders neither key would satisfy the nil assertions below
      # and this test would pass on the very defect it exists to prevent.
      assert Map.has_key?(rendered, "next_probe_at")
      assert Map.has_key?(rendered, "dark_for_seconds")

      assert rendered["auto_disabled_at"] == nil,
             "precondition: this is the HAND latch, not the automatic one"

      assert rendered["next_probe_at"] == nil,
             "only the AUTOMATIC latch gets an automatic exit — promising a probe on an " <>
               "endpoint an operator deliberately turned off is a lie about what will happen"

      assert rendered["dark_for_seconds"] == nil
    end

    test "the rendered probe time moves OUTWARD after a failed probe — the walk to the cap is visible",
         %{conn: conn} do
      wh = make_webhook(conn, "Backing off")
      latch(wh)

      first = show(conn, wh)
      {:ok, first_at, _} = DateTime.from_iso8601(first["next_probe_at"])
      first_disabled_at = Repo.get!(Webhook, wh.id).auto_disabled_at
      first_gap = DateTime.diff(first_at, first_disabled_at, :second)

      # Two further terminal give-ups past the threshold = two failed probes.
      capture_log([level: :info], fn ->
        Webhooks.record_endpoint_failure(wh.id, "http 500")
        Webhooks.record_endpoint_failure(wh.id, "http 500")
      end)

      later = show(conn, wh)
      {:ok, later_at, _} = DateTime.from_iso8601(later["next_probe_at"])
      later_disabled_at = Repo.get!(Webhook, wh.id).auto_disabled_at
      later_gap = DateTime.diff(later_at, later_disabled_at, :second)

      assert later_gap > first_gap,
             "the rendered interval must WIDEN as probes fail; a constant gap tells an " <>
               "operator a retry is imminent when the backoff has walked toward the 1h cap"

      assert DateTime.compare(later_at, first_at) == :gt,
             "the absolute probe time an operator reads must also move later"
    end
  end
end
