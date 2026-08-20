defmodule BarkparkWeb.Studio.WidthBucketSeamTest do
  @moduledoc """
  studio-space-priority-desk spd-s2 — the width-bucket server seam.

  StudioLive learns which responsive width band the desk is rendering for via a
  `width-bucket` event. This slice is deliberately INERT (no call site attaches
  the client hook yet — spd-s4 does), so the proof here is the SEAM, not the UI:

    * The assign seeds `"wide"` at mount (the zero-change desktop default).
    * A `width-bucket` event lands the new bucket on a NON-admin socket. This is
      the load-bearing proof of the `Caps.@safe_events` classification — an
      unclassified event falls to the default-DENY tier and is HALTED before the
      handler for any non-admin socket, so the assign would stay `"wide"`. The
      assign moving is exactly what proves `width-bucket` classifies `:none`.
    * A malformed / out-of-set bucket value is ignored (the fallback head keeps
      the session alive and the assign unchanged).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.TenancyFixtures

  @dataset "production"
  # A READ-ONLY api token → a clearly NON-admin socket (caps.admin == false).
  # If `width-bucket` were unclassified it would require admin and be halted for
  # this socket, so a landed assign is a non-vacuous classification proof.
  @readonly "width-bucket-readonly"

  setup %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()
    {:ok, _} = Auth.create_token(@readonly, "width-bucket readonly", @dataset, ["read"])
    {:ok, conn: conn}
  end

  defp token_view(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => token})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp width_bucket(view), do: :sys.get_state(view.pid).socket.assigns.width_bucket

  test "the assign seeds \"wide\" at mount", %{conn: conn} do
    {:ok, view, _html} = token_view(conn, @readonly)
    assert width_bucket(view) == "wide"
  end

  test "a width-bucket event lands the bucket on a NON-admin socket (@safe_events proof)", %{
    conn: conn
  } do
    {:ok, view, _html} = token_view(conn, @readonly)

    render_hook(view, "width-bucket", %{"bucket" => "narrow"})
    assert width_bucket(view) == "narrow"

    # every known band lands
    for band <- ~w(wide standard narrow phone) do
      render_hook(view, "width-bucket", %{"bucket" => band})
      assert width_bucket(view) == band
    end
  end

  test "an out-of-set bucket value is ignored (fallback head, session survives)", %{conn: conn} do
    {:ok, view, _html} = token_view(conn, @readonly)

    render_hook(view, "width-bucket", %{"bucket" => "narrow"})
    assert width_bucket(view) == "narrow"

    # garbage value → dropped by the guard; assign unchanged, view still alive.
    render_hook(view, "width-bucket", %{"bucket" => "ultrawide-garbage"})
    assert width_bucket(view) == "narrow"

    # malformed payload (no "bucket" key) → fallback head, no crash.
    render_hook(view, "width-bucket", %{})
    assert width_bucket(view) == "narrow"
    assert Process.alive?(view.pid)
  end
end
