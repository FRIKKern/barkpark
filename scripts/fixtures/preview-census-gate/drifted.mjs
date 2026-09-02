// drifted.mjs — base.mjs with one scenario MOVED to another family (#fleet ->
// #activity), name unchanged. MEASURED on the real corpus: doing this to
// `fleet-cruel-content` exits breakpoint-sweep.mjs 2 with
// `DRIFTED residue entry "fleet-cruel-content" — recorded family hash:#fleet,
// derived family is now hash:#activity` and smoke.mjs 1. A name-only trigger
// would miss it.
export const SCENARIOS = {
  "fleet-basic": { label: "a fleet", authed: true, deepLink: "#activity", data: {} },
  "site-basic": { label: "a site", authed: true, deepLink: "#site/abc", data: {} },
  "launch-page": { label: "the launch page", authed: true, pathname: "/new", data: {} },
};
