<!-- doc-tier: agent | canonical-for: paper-canvas-i18n | budget: 600tok -->

# `GET /v1/i18n/paper_canvas` — paper-canvas UI chrome strings

task-84fa11e11dacdc1b. `<bp-paper-canvas>` (the Studio's paper editor web
component) reads its UI strings from `BarkparkWeb.StudioLocale.component_strings(:paper_canvas)`, stamped as `data-strings` on the LiveView element (`api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex`). A non-LiveView host has no such element to read the attribute off of — barkpark-studio shipped its own hand-copied nb translation instead, which drifted (259/269 strings, already short). This route serves the SAME map any host can fetch, so there is one source of truth instead of two.

**Request:** `GET /v1/i18n/paper_canvas?locale=<bcp47>` — public, no token.

`locale` is one of `Barkpark.Tenancy.known_locales/0` (`en`, `nb-NO`), BCP-47 spelling. Absent or unrecognised (including the bare `nb` — the known spelling is `nb-NO`) falls back to `Tenancy.default_locale/0` (`en`) — never a refusal, the same fallback `StudioLocale.put_named/1` gives the login page.

**Response:** `200 {"locale": "<resolved bcp47>", "strings": {<key>: <value>, ...}}`.

`strings`' keys are byte-identical to `Jason.decode!(StudioLocale.component_strings(:paper_canvas))`'s keys — the controller calls that SAME function LiveView calls, so there is no second map to keep in sync and no copy that can silently drop or rename a key.

**Not a CLI surface** (`router_manifest_drift_test.exs`'s `@not_a_cli_surface`): this is a web component's own on-screen text; a terminal has no chrome to translate.
