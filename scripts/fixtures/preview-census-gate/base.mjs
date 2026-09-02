// base.mjs — the BEFORE corpus for preview-census-gate-check's self-test.
// Three scenarios over three families. Shaped like the real
// cloud/priv/static/__preview__/scenarios.mjs (a name-keyed object whose
// entries carry `deepLink` / `pathname`), because the check reads it the same
// way the instruments do: by importing it.
export const SCENARIOS = {
  "fleet-basic": { label: "a fleet", authed: true, deepLink: "#fleet", data: {} },
  "site-basic": { label: "a site", authed: true, deepLink: "#site/abc", data: {} },
  "launch-page": { label: "the launch page", authed: true, pathname: "/new", data: {} },
};
