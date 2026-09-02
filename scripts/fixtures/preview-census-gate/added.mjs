// added.mjs — base.mjs plus ONE scenario, and nothing else. This is the slice
// shape that cost wave 20 and wave 21: a fixture added, one census taught,
// the others left to refuse in the Console gate on arrival.
export const SCENARIOS = {
  "fleet-basic": { label: "a fleet", authed: true, deepLink: "#fleet", data: {} },
  "site-basic": { label: "a site", authed: true, deepLink: "#site/abc", data: {} },
  "launch-page": { label: "the launch page", authed: true, pathname: "/new", data: {} },
  "probe-new-scenario": { label: "the new one", authed: true, deepLink: "#overview", data: {} },
};
