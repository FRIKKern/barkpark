import { createServer } from "node:http";
import { profiles, profile, hostCss } from "./profiles.mjs";

function page(html, entry) {
  return html
    .replace("<head>", `<head>\n  <base href=\"/\">\n  <style>${hostCss(entry)}</style>\n  <script>window.__BP_HOST_PROFILE__=${JSON.stringify(entry)};<\/script>`)
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
