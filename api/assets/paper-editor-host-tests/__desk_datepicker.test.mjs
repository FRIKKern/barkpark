// __desk_datepicker.test.mjs: a date-time field on the desk
// (`Fields.DeskDatetime`): the text box of bp-datetime-field.js's text mode
// and the calendar of bp-desk-datepicker.js, the TanStack Studio's
// DateTimeInput.
//
//   * The box shows the stored instant in local time, "2026-09-06 11:00".
//   * The calendar button opens a dialog named "Select date" with the focus
//     on the selected day, named as TanStack names it ("Sun Sep 06 2026").
//     Arrows move a day or a week (across months); Enter picks and keeps the
//     time; the hidden input posts the instant as toISOString writes it.
//   * Tab stays in the dialog; Escape closes it and gives the focus back to
//     its button.
//   * A typed date commits on leaving the box; a typo is marked and
//     an alert says the format, and nothing posts; an emptied box posts "".
//   * Only the hidden input's events reach the form.
//   * Only a typed change is written: a box that only has the focus shows
//     another editor's value and leaving it writes nothing.
//   * A press outside closes the calendar; the focus goes to its button,
//     never <body>.
//   * In Norwegian the week starts on Monday and the days are named in
//     Norwegian.
//
// Runs the TRACKED static assets bp-datetime-field.js and
// bp-desk-datepicker.js under jsdom, in Oslo time.
//
// Run: node ../paper-editor-host-tests/__desk_datepicker.test.mjs
process.env.TZ = "Europe/Oslo";

import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/_desk/post;post-05",
});
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
globalThis.Event = window.Event;
await import("../../priv/static/assets/bp-datetime-field.js");
await import("../../priv/static/assets/bp-desk-datepicker.js");
assert.ok(window.BarkparkDatePicker, "the calendar registers itself");

const doc = window.document;
const STRINGS = JSON.stringify({
  select_date: "Select date",
  month: "Month",
  year: "Year",
  prev_year: "Go to previous year",
  next_year: "Go to next year",
  select_time: "Select time",
  now: "Set to current time",
  example: "e.g. %{example}",
  invalid: "Not a valid date. Use the format %{format}.",
});

function mount(value, locale = "en") {
  doc.body.innerHTML =
    `<form id="editor-form"><div id="bp-dt-wrap-publishedAt" class="bp-datetime-field datetime" data-value="${value}" data-doc="post-05" data-locale="${locale}" data-strings='${STRINGS}'>` +
    `<input type="hidden" name="doc[publishedAt]" value="${value}" data-datetime-value>` +
    `<div id="bp-dt-pick-publishedAt" phx-update="ignore" class="bp-datetime-picker"><div class="datetime-box">` +
    `<input type="text" id="publishedAt" data-datetime-text>` +
    `<button type="button" aria-label="Open calendar" aria-expanded="false" data-datetime-open></button>` +
    `</div><p class="field-error" role="alert" hidden data-datetime-error></p></div></div>` +
    `<button type="button" id="after">after</button></form>`;
  const el = doc.getElementById("bp-dt-wrap-publishedAt");
  const hook = Object.create(window.BarkparkDatetimeFieldHook);
  hook.el = el;
  hook.mounted();
  const posts = [];
  doc.getElementById("editor-form").addEventListener("input", (e) => posts.push(e.target.name || e.target.tagName));
  return {
    hook,
    el,
    posts,
    text: doc.getElementById("publishedAt"),
    hidden: el.querySelector("[data-datetime-value]"),
    button: el.querySelector("[data-datetime-open]"),
    error: el.querySelector("[data-datetime-error]"),
  };
}

const press = (el, key, init = {}) => {
  const e = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  el.dispatchEvent(e);
  return e;
};
const dialog = () => doc.querySelector('[role="dialog"]');
const active = () => doc.activeElement;
const leave = (el) => el.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true }));
const type = (el, value) => {
  el.value = value;
  el.dispatchEvent(new window.Event("input", { bubbles: true }));
};
// What a LiveView patch does when the server holds a new value: the hidden
// input and the wrapper's data-value change, then the hook's updated() runs.
const remote = (f, value) => {
  f.hidden.value = value;
  f.el.setAttribute("data-value", value);
  f.hook.updated();
};
const mousedown = (el) => {
  const e = new window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
  el.dispatchEvent(e);
  return e;
};

// The box shows local time; the calendar opens on the selected day.
{
  const f = mount("2026-09-06T09:00:00Z");
  assert.equal(f.text.value, "2026-09-06 11:00", "the stored instant in Oslo time");
  assert.match(f.text.placeholder, /^e\.g\. \d{4}-\d{2}-\d{2} \d{2}:\d{2}$/, "the placeholder is an example");

  f.button.click();
  const d = dialog();
  assert.ok(d, "the calendar opens");
  assert.equal(d.getAttribute("aria-label"), "Select date");
  assert.equal(f.button.getAttribute("aria-expanded"), "true");
  assert.equal(active().getAttribute("aria-label"), "Sun Sep 06 2026", "the focus is on the selected day");
  assert.equal(active().getAttribute("aria-pressed"), "true");
  assert.equal(active().getAttribute("tabindex"), "0");
  assert.equal(d.querySelectorAll('.dp-grid button[tabindex="0"]').length, 1, "one day is in the Tab order");
  assert.equal(d.querySelector('select[aria-label="Month"]').value, "8");
  assert.equal(d.querySelector('input[aria-label="Year"]').value, "2026");
  assert.equal(d.querySelector('input[aria-label="Select time"]').value, "11:00");
  assert.equal(d.querySelector(".dp-weekday").textContent, "Sun", "the English week starts on Sunday");

  // ArrowRight, Enter: the next day, at the same time.
  press(active(), "ArrowRight");
  assert.equal(active().getAttribute("aria-label"), "Mon Sep 07 2026");
  assert.equal(f.posts.length, 0, "moving posts nothing");
  press(active(), "Enter");
  assert.equal(f.hidden.value, "2026-09-07T09:00:00.000Z", "stored as toISOString writes it");
  assert.equal(f.text.value, "2026-09-07 11:00");
  assert.deepEqual(f.posts, ["doc[publishedAt]"], "the hidden input posts once");
  assert.equal(active().getAttribute("aria-label"), "Mon Sep 07 2026", "the focus stays on the day");
  assert.equal(active().getAttribute("aria-pressed"), "true");

  // A week down and back; across a month.
  press(active(), "ArrowDown");
  assert.equal(active().getAttribute("aria-label"), "Mon Sep 14 2026");
  press(active(), "ArrowUp");
  press(active(), "ArrowUp");
  press(active(), "ArrowLeft");
  assert.equal(active().getAttribute("aria-label"), "Sun Aug 30 2026");
  assert.equal(dialog().querySelector('select[aria-label="Month"]').value, "7", "the month follows");

  // Tab goes round the dialog.
  const now = [...dialog().querySelectorAll("button")].find((b) => b.textContent === "Set to current time");
  now.focus();
  assert.ok(press(now, "Tab").defaultPrevented);
  assert.equal(active(), dialog().querySelector('select[aria-label="Month"]'), "Tab from the last control goes to the first");
  assert.ok(press(active(), "Tab", { shiftKey: true }).defaultPrevented);
  assert.equal(active(), now, "Shift+Tab from the first goes to the last");

  // The year buttons.
  dialog().querySelector('button[aria-label="Go to next year"]').click();
  assert.equal(dialog().querySelector('input[aria-label="Year"]').value, "2027");
  assert.equal(f.posts.length, 1, "browsing posts nothing");

  // Escape: closed, the focus on its button.
  const esc = press(active(), "Escape");
  assert.ok(esc.defaultPrevented);
  assert.equal(dialog(), null, "Escape closes the calendar");
  assert.equal(active(), f.button, "the focus goes back to the button");
  assert.equal(f.button.getAttribute("aria-expanded"), "false");

  // "Set to current time".
  f.button.click();
  const before = Date.now();
  [...dialog().querySelectorAll("button")].find((b) => b.textContent === "Set to current time").click();
  const set = Date.parse(f.hidden.value);
  assert.ok(Math.abs(set - before) < 61_000, "now is stored");
  assert.match(f.text.value, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/);
  assert.notEqual(f.text.value, "2026-09-07 11:00");
  f.button.click();
  assert.equal(dialog(), null, "the button closes it again");
}

// Typing: commits on leaving the box; a typo posts nothing; empty clears.
{
  const f = mount("2026-09-06T09:00:00Z");
  f.text.focus();
  f.text.value = "2026-12-24 18:3";
  f.text.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(f.posts.length, 0, "the box's own input never reaches the form");
  type(f.text, "2026-12-24 18:30");
  leave(f.text);
  assert.equal(f.hidden.value, "2026-12-24T17:30:00.000Z", "a typed date is stored at leaving");
  assert.deepEqual(f.posts, ["doc[publishedAt]"]);

  type(f.text, "2026-13-40 10:00");
  leave(f.text);
  assert.equal(f.hidden.value, "2026-12-24T17:30:00.000Z", "a typo is not stored");
  assert.equal(f.posts.length, 1);
  assert.ok(f.el.hasAttribute("data-invalid"));
  assert.equal(f.text.getAttribute("aria-invalid"), "true");
  assert.equal(f.error.hidden, false);
  assert.equal(f.error.textContent, "Not a valid date. Use the format 2026-09-06 11:00.");

  type(f.text, "2026-12-25 08:00");
  assert.ok(press(f.text, "Enter").defaultPrevented, "Enter commits");
  assert.equal(f.hidden.value, "2026-12-25T07:00:00.000Z");
  assert.ok(!f.el.hasAttribute("data-invalid"), "the mark goes");
  assert.equal(f.error.hidden, true);

  type(f.text, "");
  leave(f.text);
  assert.equal(f.hidden.value, "", "an emptied box clears the field");
  assert.equal(f.posts.length, 3);

  // An untouched box posts nothing.
  const g = mount("2026-09-06T09:00:00Z");
  leave(g.text);
  assert.equal(g.posts.length, 0);
}

// Another editor's date while the box only has the focus: the box shows it,
// and leaving the box writes nothing. Only a typed change is written.
{
  const f = mount("2026-09-06T09:00:00.000Z");
  f.text.focus();
  remote(f, "2026-10-10T08:10:00Z");
  assert.equal(f.text.value, "2026-10-10 10:10", "the focused, untyped box shows the new value");
  leave(f.text);
  assert.equal(f.hidden.value, "2026-10-10T08:10:00Z", "the other editor's date stays");
  assert.equal(f.posts.length, 0, "leaving an untyped box posts nothing");
  assert.equal(press(f.text, "Enter").defaultPrevented, true);
  assert.equal(f.posts.length, 0, "Enter in an untyped box posts nothing");

  // Typing, then a remote value: the typed text stays and is written.
  type(f.text, "2026-11-01 12:00");
  remote(f, "2026-10-11T08:10:00Z");
  assert.equal(f.text.value, "2026-11-01 12:00", "the box keeps what is being typed");
  leave(f.text);
  assert.equal(f.hidden.value, "2026-11-01T11:00:00.000Z");
  assert.deepEqual(f.posts, ["doc[publishedAt]"]);

  // After the write, the box follows the server again.
  f.text.focus();
  remote(f, "2026-12-01T08:00:00Z");
  assert.equal(f.text.value, "2026-12-01 09:00");
}

// A press outside the calendar closes it and the focus goes back to its
// button: on a spot that takes no focus the press's default is stopped (it
// moved the focus to <body>); a press on a control is left alone.
{
  const f = mount("2026-09-06T09:00:00Z");
  const blank = doc.createElement("div");
  doc.getElementById("editor-form").appendChild(blank);
  f.button.click();
  assert.ok(dialog());
  const e = mousedown(blank);
  assert.equal(dialog(), null, "a press outside closes it");
  assert.equal(e.defaultPrevented, true, "a blank spot's press does not move the focus");
  assert.equal(active(), f.button, "the focus is on the button");

  f.button.click();
  const after = doc.getElementById("after");
  const onControl = mousedown(after);
  assert.equal(dialog(), null);
  assert.equal(onControl.defaultPrevented, false, "a press on a control moves the focus there");

  f.button.click();
  const inside = mousedown(dialog().querySelector(".dp-grid button"));
  assert.ok(dialog(), "a press inside keeps it open");
  assert.equal(inside.defaultPrevented, false);
  press(active(), "Escape");
}

// Norwegian: the week starts on Monday, the days are named in Norwegian.
{
  const f = mount("2026-09-06T09:00:00Z", "nb");
  f.button.click();
  assert.equal(dialog().querySelector(".dp-weekday").textContent, "Man");
  assert.equal(active().getAttribute("aria-label"), "søndag 6. september 2026");
  assert.equal(dialog().querySelector('select[aria-label="Month"] option[value="8"]').textContent, "September");
  press(active(), "Escape");
}

console.log("desk datepicker: ok");
