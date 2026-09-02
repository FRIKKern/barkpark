// removed.mjs — base.mjs MINUS one scenario. A removal moves the census the
// other way: smoke.mjs's orphan arm ("expectation(s) name a scenario that does
// not exist") and breakpoint-sweep's STALE arm both key on it.
export const SCENARIOS = {
  "fleet-basic": { label: "a fleet", authed: true, deepLink: "#fleet", data: {} },
  "launch-page": { label: "the launch page", authed: true, pathname: "/new", data: {} },
};
