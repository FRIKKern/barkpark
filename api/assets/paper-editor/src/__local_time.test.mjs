// task-7a12da688a06f880: Studio's history printed the stored UTC time with no
// zone, so an Oslo editor saw their own edit as two hours old. The server now
// renders <time datetime=ISO> whose text says UTC; Hooks.LocalTime (inline in
// root.html.heex) rewrites it in the page language and the browser's zone, and
// fills each Restore button's aria-label from its {time} template.
//
// The zone is the PROCESS's: set it before anything formats a date.
process.env.TZ = "Europe/Oslo";

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(
  new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);
const start = root.indexOf("Hooks.LocalTime = {");
assert.ok(start > 0, "root.html.heex defines Hooks.LocalTime");
const end = root.indexOf("\n    };", start);
const source = root.slice(start + "Hooks.LocalTime = ".length, end + "\n    }".length);

const render = (lang) => {
  const dom = new JSDOM(
    `<html lang="${lang}"><body><div id="history-list">
       <time class="history-item-time" datetime="2026-10-09T14:32:25Z" data-local-time>09. okt. 2026 kl. 14:32:25 UTC</time>
       <button aria-label="Gjenopprett versjonen fra 09. okt. 2026 kl. 14:32:25 UTC (Redigert)"
               data-datetime="2026-10-09T14:32:25Z"
               data-local-label="Gjenopprett versjonen fra {time} (Redigert)">Gjenopprett</button>
       <time datetime="not a date" data-local-time>left alone UTC</time>
     </div></body></html>`,
    { runScripts: "outside-only" },
  );
  const { window } = dom;
  const hookDef = window.eval(`(${source})`);
  const hook = Object.assign(Object.create(hookDef), {
    el: window.document.getElementById("history-list"),
  });
  hook.mounted();
  return window.document;
};

const doc = render("nb-NO");
const [time, bad] = doc.querySelectorAll("time");
const button = doc.querySelector("button");

// 14:32:25Z is 16:32:25 in Oslo on 9 October (CEST, UTC+2).
assert.match(time.textContent, /16[:.]32[:.]25/, "the time is the viewer's clock, not UTC");
assert.doesNotMatch(time.textContent, /UTC/, "the UTC fallback text is replaced");
assert.match(time.textContent, /okt/, "the month is in the page language");
assert.equal(
  button.getAttribute("aria-label"),
  `Gjenopprett versjonen fra ${time.textContent} (Redigert)`,
  "the Restore button names the same local time",
);
assert.equal(bad.textContent, "left alone UTC", "an unparseable datetime keeps the server text");

// The page language drives the words: an English page reads "Oct".
const en = render("en");
assert.match(en.querySelector("time").textContent, /Oct/);
assert.match(en.querySelector("time").textContent, /0?4[:.]32[:.]25\s?PM|16[:.]32[:.]25/);

console.log("local_time: ok");
