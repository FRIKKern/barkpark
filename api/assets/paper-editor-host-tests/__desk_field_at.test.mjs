// __desk_field_at.test.mjs — a read-only pane's date-time with its time.
// Walk 2 on 2026-11-13: a "Published at" read 27.09.2026 with no hour in a
// read-only document pane, while the editor's datetime field beside it showed
// the day and the time. The pane now draws <time data-desk-at> with the UTC
// day and time, and bp-desk.js shows it as the editor's field does: the
// browser's locale, day and HH:MM, in the zone the page names
// (data-time-zone) or else the browser's. One already on the page is shown
// when the desk mounts; one added later sends "desk:at" (phx-mounted).
//
// Run: node ../paper-editor-host-tests/__desk_field_at.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/post;p1",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-desk.js");

const ISO = "2026-09-27T09:00:00Z";
const parts = { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" };
const shown = (zone) => new Intl.DateTimeFormat(undefined, zone ? { ...parts, timeZone: zone } : parts).format(new Date(ISO));

window.document.body.innerHTML = `<div id="desk-panes">
  <section class="pane-column dk-pane" data-pane-index="1" data-pane-kind="doc"><dl class="dk-fields">
    <div><dt>Published at</dt><dd><time id="at-0" datetime="${ISO}" data-desk-at phx-update="ignore">27.09.2026 09:00 UTC</time></dd></div>
  </dl></section></div>`;
const el = window.document.getElementById("desk-panes");
Object.defineProperty(el, "clientWidth", { get: () => 1440 });
const hook = Object.assign(Object.create(window.BarkparkDesk), { el, pushEvent() {}, handleEvent() {} });
hook.mounted();

const doc = window.document;
assert.equal(doc.getElementById("at-0").textContent, shown(""), "on the page at mount: the day and time in the browser's zone and locale");
assert.notEqual(doc.getElementById("at-0").textContent, "27.09.2026 09:00 UTC", "not the server's UTC text");
assert.match(doc.getElementById("at-0").textContent, /\d{2}:\d{2}/, "with its HH:MM");

// One added later (a pane read, a new value), in a page that names its zone.
const shell = doc.createElement("div");
shell.setAttribute("data-time-zone", "Europe/Oslo");
doc.body.appendChild(shell);
const later = doc.createElement("time");
later.id = "at-1";
later.setAttribute("datetime", ISO);
later.setAttribute("data-desk-at", "");
later.textContent = "27.09.2026 09:00 UTC";
doc.querySelector("dd").appendChild(later);
later.dispatchEvent(new window.CustomEvent("desk:at", { bubbles: true }));
assert.equal(later.textContent, shown("Europe/Oslo"), "added: shown in the zone the page names");
assert.match(later.textContent, /11:00/, "09:00 UTC is 11:00 in Oslo in September");

// Anything else that sends the event is left alone.
const other = doc.createElement("span");
other.textContent = "keep";
doc.querySelector("dd").appendChild(other);
other.dispatchEvent(new window.CustomEvent("desk:at", { bubbles: true }));
assert.equal(other.textContent, "keep", "only a time[data-desk-at] is rewritten");

hook.destroyed();
console.log("desk field at: ok");
window.close();
