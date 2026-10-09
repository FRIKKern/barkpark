defmodule BarkparkWeb.I18nController do
  @moduledoc """
  `GET /v1/i18n/paper_canvas` — task-84fa11e11dacdc1b.

  `<bp-paper-canvas>` (the Studio's paper editor web component) reads its UI
  strings from `BarkparkWeb.StudioLocale.component_strings(:paper_canvas)`,
  stamped as `data-strings` on the LiveView element
  (`paper_editor.ex`). Non-LiveView hosts — barkpark-studio's own editor —
  have no LiveView render to read that attribute off of, so they shipped
  their OWN copy of the nb translation, hand-extracted and already 10 strings
  short of the real map. This route hands back the SAME map LiveView stamps,
  so any host can fetch it and stay in sync — no second copy to drift.

  Public and unauthenticated on purpose: this is UI chrome text, not content,
  and every surface that would ever call this already shows the same strings
  to an anonymous visitor via the LiveView render path.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias BarkparkWeb.StudioLocale

  @doc """
  `?locale=` — one of `Tenancy.known_locales/0` (`"en"`, `"nb-NO"`), BCP-47
  spelling. Absent or unrecognised falls back to `Tenancy.default_locale/0`
  (`"en"`) — the SAME fallback `StudioLocale.put_named/1` already gives the
  login page, never a 400: a caller asking for a locale this instance does
  not ship is not a malformed request, just one answered in English.
  """
  def paper_canvas(conn, params) do
    requested = Map.get(params, "locale")

    locale =
      if is_binary(requested) and requested in Tenancy.known_locales() do
        requested
      else
        Tenancy.default_locale()
      end

    # `put_named/1` is the SAME seam the login page uses to resolve a BCP-47
    # locale onto the current process before any `gettext/1` call — it sets
    # Gettext's process locale so `component_strings/1`'s own `gettext/1`
    # calls resolve in `locale`, not whatever this process last rendered in.
    StudioLocale.put_named(locale)

    strings = :paper_canvas |> StudioLocale.component_strings() |> Jason.decode!()

    json(conn, %{locale: locale, strings: strings})
  end
end
