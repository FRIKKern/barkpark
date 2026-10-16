// datetime-picker.mjs — opens a Studio document in a real browser and reads
// every date-time picker (task-cf45242ef3477fba).
//
// The gyldendal.no twin's event 2026-10-29T14:00:00Z showed "dd/mm/yyyy, --:--":
// the hook filled the picker, then the next LiveView patch reset it to "".
// A server-side render test cannot see that, so this drives Chromium.
//
// For each `.bp-datetime-field` it compares the picker's value with the stored
// value (the hidden input) shown in the browser's time zone, after the page
// has settled and after one more LiveView patch (a keystroke in the title).
//
// Usage (Playwright must resolve from the working directory):
//   BP_BASE=http://localhost:4130 BP_TOKEN=<admin token> \
//   BP_STUDIO=/w/gyldendal-no/p/default/d/production/studio \
//   BP_DOC=event/fdb8176c-7e0a-4101-976c-15e583c12ab0 \
//   [BP_TZ=Europe/Oslo] [BP_CHROME=/path/to/chrome] node tooling/studio-fields/datetime-picker.mjs
//
// The patch step types a space into the title and deletes it, so it saves a
// draft. Run it against a copy of the content, never a production Studio.
//
// The token mints a one-time login ticket (POST /v1/auth/login-tickets) and is
// never printed. Exit 0 when every picker shows its stored value, 1 otherwise.
import { chromium } from "playwright";

const { BP_BASE, BP_TOKEN, BP_STUDIO, BP_DOC } = process.env;
const TZ = process.env.BP_TZ || "Europe/Oslo";

if (!BP_BASE || !BP_TOKEN || !BP_STUDIO || !BP_DOC) {
  console.error("set BP_BASE, BP_TOKEN, BP_STUDIO and BP_DOC");
  process.exit(2);
}

const ticket = await fetch(BP_BASE + "/v1/auth/login-tickets", {
  method: "POST",
  headers: { Authorization: "Bearer " + BP_TOKEN, "content-type": "application/json" },
  body: "{}",
}).then((r) => r.json());

const browser = await chromium.launch(process.env.BP_CHROME ? { executablePath: process.env.BP_CHROME } : {});
const ctx = await browser.newContext({ timezoneId: TZ });
const page = await ctx.newPage();
await page.goto(BP_BASE + "/login/ticket/" + ticket.ticket);
await page.goto(BP_BASE + BP_STUDIO + "/" + BP_DOC, { timeout: 120000 });
await page.waitForSelector(".bp-datetime-field", { timeout: 120000 });
await page.waitForTimeout(3000);

// What the picker should show: the stored instant in the browser's zone.
const read = () =>
  page.evaluate(() =>
    [...document.querySelectorAll(".bp-datetime-field")].map((w) => {
      const stored = w.querySelector("[data-datetime-value]").value;
      const shown = w.querySelector('input[type="datetime-local"]').value;
      let want = "";
      if (/(?:[zZ]|[+-]\d{2}:?\d{2})$/.test(stored)) {
        const d = new Date(stored);
        const p = (n) => String(n).padStart(2, "0");
        want = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
      } else if (stored) {
        want = stored.slice(0, 16);
      }
      return { name: w.querySelector("[data-datetime-value]").name, stored, shown, want };
    })
  );

let failed = 0;
const report = (label, rows) => {
  for (const r of rows) {
    const ok = r.shown === r.want;
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"}  ${label}  ${r.name}  stored=${r.stored}  picker=${r.shown || "(empty)"}  want=${r.want}`);
  }
};

report("on open", await read());

// One more LiveView patch: type into the title and wait for the round trip.
const title = page.locator('input[name="doc[title]"]');
if (await title.count()) {
  await title.press("End");
  await title.type(" ");
  await page.waitForTimeout(2500);
  await title.press("Backspace");
  await page.waitForTimeout(2500);
  report("after a patch", await read());
}

await browser.close();
process.exit(failed ? 1 : 0);
