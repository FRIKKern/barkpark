import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { profiles, profile, hostCss } from "./profiles.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../../../..");

function page(html, entry) {
  const pickers = entry.pickers ? '\n  <script src="/host-assets/bp-media-picker.js" defer></script>\n  <script src="/host-assets/bp-reference-picker.js" defer></script>' : "";
  return html
    .replace("<head>", `<head>\n  <base href=\"/\">\n  <style>${hostCss(entry)}</style>\n  <script>window.__BP_HOST_PROFILE__=${JSON.stringify(entry)};<\/script>${pickers}`)
    .replace("<body>", `<body class=\"${entry.className.split(" ").map((name) => `host-${name}`).join(" ")}\">`)
    .replace("<title>Editor testing ground</title>", `<title>${entry.title} host journey</title>`);
}

export async function startHostServer({ testingGround }) {
  const source = await (await fetch(testingGround.url)).text();
  const server = createServer(async (req, res) => {
    const asked = new URL(req.url, "http://localhost");
    const match = asked.pathname.match(/^\/hosts\/([^/]+)\/$/);
    if (match) {
      const entry = profile(match[1]);
      if (!entry) {
        res.statusCode = 404;
        return res.end("unknown host");
      }
      res.setHeader("content-type", "text/html");
      res.setHeader("cache-control", "no-store");
      return res.end(page(source, entry));
    }
    if (asked.pathname === "/hosts.json") {
      res.setHeader("content-type", "application/json");
      return res.end(JSON.stringify(profiles));
    }
    const asset = asked.pathname.match(/^\/host-assets\/(bp-(?:media|reference)-picker\.js)$/)?.[1];
    if (asset) {
      res.setHeader("content-type", "text/javascript");
      res.setHeader("cache-control", "no-store");
      return res.end(readFileSync(join(REPO, "api/priv/static/assets", asset)));
    }
    try {
      const upstream = await fetch(new URL(asked.pathname + asked.search, testingGround.url));
      res.statusCode = upstream.status;
      for (const [name, value] of upstream.headers) if (!["content-encoding", "content-length"].includes(name)) res.setHeader(name, value);
      res.end(Buffer.from(await upstream.arrayBuffer()));
    } catch (error) {
      res.statusCode = 502;
      res.end(`testing-ground proxy failed: ${error.message}`);
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
