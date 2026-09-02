// label-only.mjs — base.mjs with ONE label retuned. The census does not move:
// same names, same families. MEASURED on the real corpus at origin/main@9e04f46
// — the same edit leaves smoke.mjs, breakpoint-sweep.mjs,
// breakpoint-sweep.test.mjs and member-authority-sweep.mjs all at exit 0. This
// fixture is the negative arm: the rule must stay QUIET here, or it turns every
// Console slice into a full-harness run.
export const SCENARIOS = {
  "fleet-basic": { label: "a fleet, described better", authed: true, deepLink: "#fleet", data: {} },
  "site-basic": { label: "a site", authed: true, deepLink: "#site/abc", data: {} },
  "launch-page": { label: "the launch page", authed: true, pathname: "/new", data: {} },
};
