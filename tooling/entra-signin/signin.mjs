#!/usr/bin/env node
// Headless Entra sign-in to a Barkpark organization's OIDC connection.
//
// It opens /v1/auth/oidc/<org>/start with a Studio return_to, signs the user
// in on the real Entra pages (username, password, TOTP, "Stay signed in?" No),
// takes the ticket the callback sends to the return_to origin, exchanges it at
// POST /v1/auth/sso/exchange and reads the session's seats from
// GET /v1/auth/token. Nothing listens on the return_to origin: the browser
// request to it is intercepted. The origin must be in the instance's
// BARKPARK_STUDIO_SSO_ORIGINS.
//
// Secrets come from files and are never printed: the password from
// --password-file, the TOTP secret (base32) from --totp-file. With
// --enroll-totp, a user that Entra asks to register MFA gets a third-party
// authenticator app registered, and its secret is written to --totp-file
// with mode 600.
//
// Output is one JSON object on stdout. Exit 0 when the sign-in reached
// Barkpark and a session was read, 2 when Barkpark or Entra refused it, 1 on
// a harness error.

import { chromium } from "playwright";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const USAGE = `usage: node signin.mjs --host <https://host> --org <slug> --user <upn>
  --password-file <file> [--totp-file <file>] [--enroll-totp]
  [--studio-origin http://localhost:3000] [--save-token <file>] [--logout]
  [--check-token <file>] [--debug-dir <dir>] [--headed] [--timeout-s 120]

--check-token <file> skips the sign-in and reads GET /v1/auth/token with a
token saved by an earlier --save-token run.`;

function parseArgs(argv) {
  const a = { studioOrigin: "http://localhost:3000", timeoutS: 120 };
  const flags = {
    "--host": "host", "--org": "org", "--user": "user",
    "--password-file": "passwordFile", "--totp-file": "totpFile",
    "--studio-origin": "studioOrigin", "--save-token": "saveToken",
    "--check-token": "checkToken", "--debug-dir": "debugDir", "--timeout-s": "timeoutS",
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--enroll-totp") a.enrollTotp = true;
    else if (k === "--headed") a.headed = true;
    else if (k === "--logout") a.logout = true;
    else if (k === "-h" || k === "--help") { console.log(USAGE); process.exit(0); }
    else if (flags[k] && i + 1 < argv.length) a[flags[k]] = argv[++i];
    else { console.error(`unknown or incomplete argument: ${k}\n${USAGE}`); process.exit(1); }
  }
  if (!a.host) { console.error(USAGE); process.exit(1); }
  a.host = a.host.replace(/\/+$/, "");
  if (!a.checkToken && !(a.org && a.user && a.passwordFile)) { console.error(USAGE); process.exit(1); }
  a.timeoutS = Number(a.timeoutS);
  return a;
}

// RFC 4648 base32 and RFC 6238 TOTP (SHA-1, 30 s, 6 digits), as Entra uses.
function base32Decode(s) {
  const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, "");
  let bits = 0, value = 0;
  const out = [];
  for (const ch of clean) {
    value = (value << 5) | alpha.indexOf(ch);
    bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return Buffer.from(out);
}

function totp(secret, t = Date.now()) {
  const counter = Math.floor(t / 1000 / 30);
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const h = crypto.createHmac("sha1", base32Decode(secret)).update(buf).digest();
  const o = h[h.length - 1] & 0xf;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1_000_000).padStart(6, "0");
}

// Entra refuses a code it has already accepted. Use a fresh 30 s window with
// at least 5 s left.
async function freshCode(secret, stampFile) {
  const now = Date.now();
  const win = Math.floor(now / 30000);
  let last = -1;
  try { last = Number(fs.readFileSync(stampFile, "utf8")); } catch {}
  let wait = 0;
  if (win === last) wait = (win + 1) * 30000 - now + 500;
  else if (30000 - (now % 30000) < 5000) wait = 30000 - (now % 30000) + 500;
  if (wait) await new Promise((r) => setTimeout(r, wait));
  const t = Date.now();
  try { fs.writeFileSync(stampFile, String(Math.floor(t / 30000)), { mode: 0o600 }); } catch {}
  return totp(secret, t);
}

const b64url = (b) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const log = (msg) => process.stderr.write(`[entra-signin] ${msg}\n`);
const readSecret = (f) => fs.readFileSync(f, "utf8").trim();

async function readSeats(host, token) {
  const res = await fetch(`${host}/v1/auth/token`, {
    headers: { authorization: `Bearer ${token}`, accept: "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  return {
    status: res.status,
    kind: body.kind,
    user: body.user,
    expires_at: body.expires_at,
    seats: (body.seats || []).map((s) => ({ workspace: s.workspace?.slug, role: s.role })),
    error: body.error ? { code: body.error.code, message: body.error.message } : undefined,
  };
}

async function main() {
  const a = parseArgs(process.argv.slice(2));

  if (a.checkToken) {
    const out = await readSeats(a.host, readSecret(a.checkToken));
    console.log(JSON.stringify({ mode: "check-token", ...out }, null, 2));
    process.exit(out.status === 200 ? 0 : 2);
  }

  const password = readSecret(a.passwordFile);
  let totpSecret = a.totpFile && fs.existsSync(a.totpFile) ? readSecret(a.totpFile) : null;
  const stampFile = a.totpFile ? `${a.totpFile}.last-window` : null;
  if (a.debugDir) fs.mkdirSync(a.debugDir, { recursive: true });

  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash("sha256").update(verifier).digest());
  const state = b64url(crypto.randomBytes(16));
  const returnTo = `${a.studioOrigin}/entra-signin-harness`;
  const startUrl = `${a.host}/v1/auth/oidc/${encodeURIComponent(a.org)}/start?` +
    new URLSearchParams({ return_to: returnTo, state, code_challenge: challenge, code_challenge_method: "S256" });

  const browser = await chromium.launch({ headless: !a.headed });
  const context = await browser.newContext({ locale: "en-US" });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);

  let ticketUrl = null;
  await context.route(`${a.studioOrigin}/**`, (route) => {
    ticketUrl = route.request().url();
    route.fulfill({ status: 200, contentType: "text/plain", body: "ticket received" });
  });
  let callback = null;
  page.on("response", (r) => {
    if (r.url().startsWith(`${a.host}/v1/auth/oidc/`) && r.url().includes("/callback")) {
      callback = { status: r.status() };
      // Chromium may block the navigation from a public origin to a loopback
      // return_to, so take the ticket from the redirect itself.
      const loc = r.headers()["location"];
      if (loc && loc.startsWith(a.studioOrigin)) ticketUrl = loc;
    }
  });

  const steps = [];
  let shot = 0;
  let secretOnScreen = false;
  const snap = async (label) => {
    if (!a.debugDir) return;
    if (/Secret key/i.test(await bodyText())) return;
    const f = path.join(a.debugDir, `${String(++shot).padStart(2, "0")}-${label}.png`);
    await page.screenshot({ path: f, fullPage: true }).catch(() => {});
  };
  const step = (s) => { steps.push(s); log(s); };
  // Entra keeps the other page's field in the DOM at opacity 0 and 10x13 px
  // (the username page holds a password field and the reverse), so a field
  // counts only when it is opaque and full size.
  const firstVisible = async (sel) => {
    for (const el of await page.locator(sel).all().catch(() => [])) {
      const shown = await el.evaluate((e) => {
        const r = e.getBoundingClientRect();
        const s = getComputedStyle(e);
        return s.visibility !== "hidden" && s.display !== "none" && Number(s.opacity) > 0 && r.width > 20 && r.height > 8;
      }).catch(() => false);
      if (shown) return el;
    }
    return null;
  };
  const visible = async (sel) => (await firstVisible(sel)) !== null;
  const clickIf = async (sel) => {
    const el = page.locator(sel).first();
    if (await el.isVisible().catch(() => false)) { await el.click(); return true; }
    return false;
  };
  const bodyText = async () => (await page.locator("body").innerText().catch(() => "")).slice(0, 4000);

  const result = { mode: "sign-in", upn: a.user, org: a.org, steps };
  let outcome = "error";
  const deadline = Date.now() + a.timeoutS * 1000;
  let passwordSent = false;
  let codeTries = 0;

  try {
    await page.goto(startUrl, { waitUntil: "domcontentloaded" });

    while (Date.now() < deadline) {
      await page.waitForLoadState("domcontentloaded").catch(() => {});
      await page.waitForTimeout(1200);
      const url = new URL(page.url());

      if (ticketUrl) { step("ticket received at the return_to origin"); break; }
      if (url.origin === new URL(a.host).origin && url.pathname.includes("/callback")) {
        result.barkpark_refusal = { status: callback?.status, text: (await bodyText()).slice(0, 600) };
        step(`Barkpark refused the callback (${callback?.status})`);
        await snap("barkpark-refused");
        outcome = "refused";
        break;
      }
      if (url.origin === new URL(a.host).origin) {
        result.barkpark_page = { path: url.pathname, text: (await bodyText()).slice(0, 600) };
        step(`stopped on a Barkpark page ${url.pathname}`);
        await snap("barkpark-page");
        outcome = "refused";
        break;
      }

      // An Entra error page with an AADSTS code, such as AADSTS50105 for a
      // user the app is not assigned to.
      const aadsts = url.hostname === "login.microsoftonline.com" && (await bodyText()).match(/AADSTS(\d+): ([^\n]{0,300})/);
      if (aadsts && !(await visible("input[name=passwd], input[name=otc], input[name=loginfmt]"))) {
        result.entra_code = `AADSTS${aadsts[1]}`;
        result.entra_error = aadsts[2];
        step(`Entra error: ${result.entra_code}`);
        await snap("entra-error");
        outcome = "refused";
        break;
      }
      // Entra error pages: disabled account, wrong password, blocked sign-in.
      const err = page.locator("#usernameError, #passwordError, #idTD_Error, #service_exception_message, .error.ext-error").first();
      if (await err.isVisible().catch(() => false)) {
        const text = (await err.innerText().catch(() => "")).trim();
        if (text) {
          result.entra_error = text.slice(0, 400);
          const code = (await bodyText()).match(/AADSTS\d+/);
          if (code) result.entra_code = code[0];
          step(`Entra error: ${result.entra_error.split("\n")[0]}`);
          await snap("entra-error");
          outcome = "refused";
          break;
        }
      }

      if (await visible("input[name=loginfmt]")) {
        step("username");
        await page.fill("input[name=loginfmt]", a.user);
        await page.click("#idSIButton9");
        await page.waitForTimeout(1500);
        continue;
      }
      if (await visible("input[name=passwd]")) {
        if (passwordSent) throw new Error("Entra showed the password page again");
        step("password");
        await page.fill("input[name=passwd]", password);
        passwordSent = true;
        await page.click("#idSIButton9");
        continue;
      }
      // "Verify your identity" method picker: choose the authenticator code.
      if (await visible("[data-value=PhoneAppOTP]")) {
        step("method picker: verification code");
        await page.click("[data-value=PhoneAppOTP]");
        continue;
      }
      if (await visible("#signInAnotherWay")) {
        step("other way to sign in");
        await page.click("#signInAnotherWay");
        continue;
      }
      if (await visible("input[name=otc]")) {
        if (!totpSecret) throw new Error("Entra asks for a TOTP code and no --totp-file secret exists");
        if (++codeTries > 2) throw new Error("Entra refused the TOTP code twice");
        step("TOTP code");
        await page.fill("input[name=otc]", await freshCode(totpSecret, stampFile));
        await page.locator("#idSubmit_SAOTCC_Continue, input[type=submit]").first().click();
        continue;
      }
      // "Stay signed in?": No.
      if (await visible("#KmsiCheckboxField") || (await visible("#idBtn_Back") && /stay signed in/i.test(await bodyText()))) {
        step("stay signed in: No");
        await page.click("#idBtn_Back");
        continue;
      }
      // "More information required": MFA registration.
      if (await visible("#idSubmit_ProofUp_Redirect")) {
        if (!a.enrollTotp) { result.entra_error = "Entra requires MFA registration; rerun with --enroll-totp"; outcome = "refused"; step(result.entra_error); break; }
        step("MFA registration required");
        await page.click("#idSubmit_ProofUp_Redirect");
        continue;
      }
      if (url.hostname === "mysignins.microsoft.com" || url.hostname === "aka.ms") {
        await snap("register");
        await enrollTotp();
        continue;
      }
      // Consent prompt for the app.
      if (await visible("#idBtn_Accept") && /permissions requested/i.test(await bodyText())) {
        result.entra_error = "Entra asks the user to consent; grant admin consent for the app";
        outcome = "refused"; step(result.entra_error); await snap("consent"); break;
      }
      // A plain "Next"/"Yes" interstitial. Entra shows #idSIButton9 before the
      // username or password field finishes its slide-in, so clicking it then
      // submits an empty form. Wait, and click only if no field has appeared.
      if (await visible("#idSIButton9")) {
        await page.waitForTimeout(1000);
        if (!(await visible("input[name=loginfmt], input[name=passwd], input[name=otc]"))) {
          step("continue");
          await page.click("#idSIButton9");
        }
        continue;
      }

      await page.waitForTimeout(1500);
      if (Date.now() > deadline - 2000) break;
    }

    if (ticketUrl) {
      const u = new URL(ticketUrl);
      if (u.searchParams.get("state") !== state) throw new Error("the return_to state does not match");
      const ex = await fetch(`${a.host}/v1/auth/sso/exchange`, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ ticket: u.searchParams.get("ticket"), audience: a.studioOrigin, code_verifier: verifier }),
      });
      const body = await ex.json().catch(() => ({}));
      if (ex.status !== 201 || !body.token) throw new Error(`ticket exchange answered ${ex.status}`);
      Object.assign(result, await readSeats(a.host, body.token));
      result.session = "signed in";
      // true when Barkpark counted the Entra MFA for this session (trust_idp_mfa).
      result.idp_mfa = body.idp_mfa === true;
      if (a.saveToken) {
        fs.writeFileSync(a.saveToken, body.token + "\n", { mode: 0o600 });
        result.saved_token = a.saveToken;
      }
      if (a.logout) {
        const lo = await fetch(`${a.host}/v1/auth/logout`, { method: "DELETE", headers: { authorization: `Bearer ${body.token}`, accept: "application/json" } });
        result.logout_status = lo.status;
      }
      outcome = "ok";
    } else if (outcome === "error") {
      const u = new URL(page.url());
      // The register page shows secrets; keep its text out of the output.
      result.stuck_at = { host: u.host, path: u.pathname, text: u.host === "mysignins.microsoft.com" ? undefined : (await bodyText()).slice(0, 600) };
      await snap("stuck");
      throw new Error("the sign-in did not finish before the timeout");
    }
  } catch (e) {
    result.error = e.message;
    if (!result.stuck_at) {
      try { result.stuck_at = { host: new URL(page.url()).host, path: new URL(page.url()).pathname }; } catch {}
    }
    await snap("error");
  } finally {
    await browser.close();
  }

  result.outcome = outcome;
  console.log(JSON.stringify(result, null, 2));
  process.exit(outcome === "ok" ? 0 : outcome === "refused" ? 2 : 1);

  // Registers a third-party authenticator app on the My Sign-Ins register
  // page (mysignins.microsoft.com/register) and stores its secret. Each call
  // handles the page it finds. Text as Entra showed it on 2026-10-27.
  async function enrollTotp() {
    const codeInput = secretOnScreen && (await firstVisible("input[type=text], input[type=tel], input[type=number]"));
    if (codeInput) {
      if (++codeTries > 2) throw new Error("Entra refused the registration code twice");
      step("register: verify code");
      await codeInput.fill(await freshCode(totpSecret, stampFile));
      await clickIf("button:has-text('Next')");
      await page.waitForTimeout(3000);
      return;
    }
    const secretMatch = (await bodyText()).match(/Secret key:?\s*([a-z2-7 ]{16,})/i);
    if (secretMatch && !secretOnScreen) {
      secretOnScreen = true;
      if (!a.totpFile) throw new Error("--enroll-totp needs --totp-file");
      totpSecret = secretMatch[1].replace(/\s+/g, "").toUpperCase();
      fs.writeFileSync(a.totpFile, totpSecret + "\n", { mode: 0o600 });
      step("register: secret stored");
      await clickIf("button:has-text('Next')");
      return;
    }
    if (!secretOnScreen && (await clickIf("button:has-text('Set up a different authentication app'), button:has-text('I want to use a different authenticator app')"))) {
      step("register: different authenticator app");
      return;
    }
    if (await clickIf("button:has-text(\"Can't scan the QR code\"), button:has-text(\"Can't scan image\")")) {
      step("register: show secret");
      return;
    }
    // The Microsoft Authenticator push page needs a phone; never take it.
    if (/Enter the following into Microsoft Authenticator/i.test(await bodyText())) {
      throw new Error("Entra offered only Microsoft Authenticator push registration");
    }
    if (await clickIf("button:has-text('Done'), button:has-text('Continue')")) { step("register: done"); return; }
    if (await clickIf("button:has-text('Next')")) { step("register: next"); return; }
    await page.waitForTimeout(1500);
  }
}

main().catch((e) => { console.error(`[entra-signin] ${e.message}`); process.exit(1); });
