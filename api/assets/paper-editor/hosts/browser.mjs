import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

export const CHROME_VERSION = "148.0.7778.167";

export function defaultChromePath({ platform = process.platform, arch = process.arch, home = homedir() } = {}) {
  const root = join(home, ".cache", "puppeteer", "chrome-headless-shell");
  if (platform === "darwin" && arch === "arm64") return join(root, `mac_arm-${CHROME_VERSION}`, "chrome-headless-shell-mac-arm64", "chrome-headless-shell");
  if (platform === "darwin" && arch === "x64") return join(root, `mac-${CHROME_VERSION}`, "chrome-headless-shell-mac-x64", "chrome-headless-shell");
  if (platform === "linux" && arch === "x64") return join(root, `linux-${CHROME_VERSION}`, "chrome-headless-shell-linux64", "chrome-headless-shell");
  throw new Error(`chrome-headless-shell ${CHROME_VERSION} has no configured path for ${platform}/${arch}`);
}

export function resolveChrome(env = process.env) {
  const path = env.CHROME_HEADLESS_SHELL || defaultChromePath();
  let words;
  try {
    words = execFileSync(path, ["--version"], { encoding: "utf8" }).trim();
  } catch (error) {
    throw new Error(`chrome-headless-shell ${CHROME_VERSION} is required at ${path}: ${error.message.split("\n")[0]}`);
  }
  if (!words.endsWith(` ${CHROME_VERSION}`)) throw new Error(`chrome-headless-shell must be ${CHROME_VERSION}, got ${JSON.stringify(words)} from ${path}`);
  return { path, version: CHROME_VERSION, words };
}

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.next = 1;
    this.pending = new Map();
    socket.addEventListener("message", ({ data }) => {
      const message = JSON.parse(String(data));
      if (!message.id) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`));
      else pending.resolve(message.result);
    });
  }

  send(method, params = {}) {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { method, resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    this.socket.close();
  }
}

async function devtoolsUrl(child) {
  return await new Promise((resolve, reject) => {
    let words = "";
    const timer = setTimeout(() => reject(new Error("chrome-headless-shell did not publish a DevTools URL within 10 seconds")), 10_000);
    child.stderr.on("data", (chunk) => {
      words += chunk;
      const match = words.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`chrome-headless-shell exited before startup (${code}): ${words.trim()}`));
    });
  });
}

export async function launchChrome({ chrome = resolveChrome() } = {}) {
  const profile = mkdtempSync(join(tmpdir(), "bp-hosts-chrome-"));
  const child = spawn(chrome.path, [
    "--headless",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--disable-background-networking",
    "--disable-breakpad",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-sync",
    "--metrics-recording-only",
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  let cdp;
  try {
    const browserWs = await devtoolsUrl(child);
    const endpoint = new URL(browserWs);
    const created = await fetch(`http://${endpoint.host}/json/new?about:blank`, { method: "PUT" });
    if (!created.ok) throw new Error(`Chrome target creation failed: ${created.status}`);
    const target = await created.json();
    const socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", () => reject(new Error("Chrome target WebSocket failed")), { once: true });
    });
    cdp = new Cdp(socket);
    await Promise.all([cdp.send("Page.enable"), cdp.send("Runtime.enable")]);
  } catch (error) {
    child.kill("SIGKILL");
    rmSync(profile, { recursive: true, force: true });
    throw error;
  }

  async function close() {
    cdp.close();
    const exited = new Promise((resolve) => child.once("exit", resolve));
    child.kill("SIGTERM");
    await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 2_000))]);
    if (child.exitCode === null) child.kill("SIGKILL");
    rmSync(profile, { recursive: true, force: true });
  }
  return { chrome, cdp, close };
}

export async function evaluate(cdp, expression, { awaitPromise = true, returnByValue = true } = {}) {
  const { result, exceptionDetails } = await cdp.send("Runtime.evaluate", { expression, awaitPromise, returnByValue });
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description || exceptionDetails.text);
  return result.value;
}

export async function waitFor(cdp, expression, { timeout = 15_000, interval = 50 } = {}) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (await evaluate(cdp, expression)) return;
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
  throw new Error(`browser condition timed out: ${expression}`);
}

export async function navigate(cdp, url) {
  const token = `nav-${Date.now()}-${Math.random()}`;
  await evaluate(cdp, `window.__hostsNavigationToken = ${JSON.stringify(token)}`);
  const { errorText } = await cdp.send("Page.navigate", { url });
  if (errorText) throw new Error(`navigation failed: ${errorText}`);
  await waitFor(cdp, `window.__hostsNavigationToken !== ${JSON.stringify(token)} && document.readyState === 'complete' && Boolean(window.testingGround?.state?.canvases?.[0]?._editor)`);
}
