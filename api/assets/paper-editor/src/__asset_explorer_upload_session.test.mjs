// task-8cf148ac47fb34ae: the Media library's upload built its own headers and
// skipped the account-session header its own _headers/2 sends, so an account
// (cookie) session's upload was refused 403 csrf_required. It now sends the
// same credentials: a bearer when the page has one, otherwise x-requested-with.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  runScripts: "outside-only",
  url: "http://localhost/",
});
const { window } = dom;
window.eval(
  readFileSync(new URL("../../../priv/static/assets/bp-asset-explorer.js", import.meta.url), "utf8"),
);

const Explorer = window.customElements.get("bp-asset-explorer");
assert.ok(Explorer, "bp-asset-explorer registers its element");
const upload = Explorer.prototype._uploadFiles;

async function run(token, status = 200) {
  const calls = [];
  const toasts = [];
  window.fetch = async (url, init) => {
    calls.push({ url, headers: init.headers });
    return { ok: status < 400, status };
  };
  const host = {
    _token: () => token,
    _scopePrefix: () => "/w/agency/p/default",
    _dataset: () => "production",
    _toast: (m) => toasts.push(m),
    // The toasts read through the explorer's strings hook (task-2bc7975ad3bdb737);
    // this host stamps no strings, so they read the English.
    _t: Explorer.prototype._t,
    _setStatus: () => {},
    _loadAssets: async () => {},
  };
  const file = new window.File(["x"], "a.png", { type: "image/png" });
  await upload.call(host, [file]);
  return { calls, toasts };
}

const session = await run("");
assert.equal(session.calls.length, 1);
assert.equal(session.calls[0].url, "/w/agency/p/default/v1/media/production/upload");
assert.equal(session.calls[0].headers["x-requested-with"], "bp-asset-explorer",
  "an account session (no bearer) sends the header the cookie branch requires");
assert.equal(session.calls[0].headers.Authorization, undefined);
assert.equal(session.calls[0].headers["Content-Type"], undefined, "the browser sets the multipart boundary");

const bearer = await run("tok-1");
assert.equal(bearer.calls[0].headers.Authorization, "Bearer tok-1");
assert.equal(bearer.calls[0].headers["x-requested-with"], undefined, "a bearer caller is unchanged");

const expired = await run("", 401);
assert.ok(expired.toasts.some((t) => /sign in again/i.test(t)));
assert.ok(!expired.toasts.some((t) => /barkpark-dev-token/.test(t)), "no dev-token advice in production copy");

console.log("ok asset explorer upload: session header, bearer unchanged, honest 401 copy");
