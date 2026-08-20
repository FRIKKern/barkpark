#!/usr/bin/env python3
"""
GitHub App bootstrap via the App Manifest flow — the one-click path that replaces
manual App creation (there is no `gh app create`).

It serves a localhost page that auto-submits a pre-filled App manifest to GitHub
using YOUR logged-in github.com browser session. You click "Create GitHub App"
once; GitHub redirects back here with a temporary code; this script exchanges it
for the App's id + private key (.pem) + webhook secret and writes them to a file.

Nothing here needs a special API token — the create step is browser-session-auth'd.

Usage:
    python3 scripts/github-app-bootstrap.py \
        --name "Barkpark Bridge FRIKKern" \
        --webhook-url https://guerrilla.barkpark.cloud/v1/plugins/github/webhook \
        --out /path/to/github-app-creds.json \
        [--port 8724] [--org ORGNAME]

Then open the printed http://localhost:PORT/ in a browser, click Create, and pick
the repo to install on. Creds land in --out (chmod 600).
"""
import argparse
import http.server
import json
import os
import secrets
import socketserver
import sys
import urllib.request
import webbrowser

STATE = secrets.token_urlsafe(24)
RESULT = {"done": False, "creds": None, "error": None}


def build_manifest(name, webhook_url, redirect_url):
    # Minimal, least-privilege manifest for the Barkpark bridge.
    #   issues:write        — mirror + intake + adopt (the core loop)
    #   metadata:read       — mandatory for every App
    #   contents:read       — read repo metadata the projection may reference
    #   pull_requests:read  — REQUIRED to subscribe to the `pull_request` event.
    #
    # EVENTS ARE A CONTRACT WITH THE CODE, NOT A PREFERENCE. Every event the
    # webhook controller dispatches on must appear in `default_events` or that
    # handler is dead code that no test can notice. This list was `["issues"]`
    # for 29 days after #5742 shipped a `pull_request` consumer
    # (`Plugins.Github.MergeEvents`, the merge-gate autostamp), so GitHub never
    # sent the event, the handler was never called once, and 9 merge-gated tasks
    # in a single 40-day window went unstamped while five green unit tests said
    # the bridge worked. `scripts/github-webhook-subscription-parity.sh` now reds
    # when this list falls behind the controller.
    #
    #   issues        — intake acts on issues.opened; deleted/transferred/closed
    #                   are the InboundEvents detach bookkeeping.
    #   pull_request  — MergeEvents stamps the merge_gate:true criterion on a
    #                   merged close. Needs pull_requests:read above.
    # NOTE on Projects v2: a USER-owned Projects v2 board is not writable by a
    # GitHub App installation token today, so the board dashboard is provisioned
    # separately with your own `gh` token (see github-projects-setup.sh) and the
    # plugin fails-isolated if the App can't write it. Core mirror/intake/adopt
    # are unaffected.
    return {
        "name": name,
        "url": "https://guerrilla.barkpark.cloud",
        "hook_attributes": {"url": webhook_url, "active": True},
        "redirect_url": redirect_url,
        "public": False,
        "default_permissions": {
            "issues": "write",
            "metadata": "read",
            "contents": "read",
            "pull_requests": "read",
        },
        "default_events": ["issues", "pull_request"],
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        if self.path.startswith("/callback"):
            self._callback()
        elif self.path == "/" or self.path.startswith("/?"):
            self._form()
        else:
            self.send_error(404)

    def _form(self):
        action = self.server.create_url
        manifest_json = json.dumps(self.server.manifest)
        html = f"""<!doctype html><html><head><meta charset="utf-8">
<title>Create the Barkpark GitHub App</title>
<style>body{{font-family:system-ui;max-width:40rem;margin:4rem auto;padding:0 1rem;line-height:1.5}}
button{{font-size:1rem;padding:.6rem 1.2rem;cursor:pointer}}</style></head><body>
<h1>Create the Barkpark bridge GitHub App</h1>
<p>This submits a pre-filled manifest to GitHub using your logged-in session. On the
next page click <strong>Create GitHub App</strong>, then choose <strong>FRIKKern/barkpark</strong>
to install it on. You'll be redirected back here automatically.</p>
<form action="{action}" method="post">
  <input type="hidden" name="manifest" value='{manifest_json.replace("'", "&#39;")}'>
  <button type="submit">Continue to GitHub &rarr;</button>
</form>
<script>/* auto-submit for a true one-click */ setTimeout(()=>document.forms[0].submit(), 400);</script>
</body></html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode())

    def _callback(self):
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(self.path).query)
        code = (q.get("code") or [None])[0]
        state = (q.get("state") or [None])[0]
        if state != STATE:
            self._fail("state mismatch — aborting (possible CSRF).")
            return
        if not code:
            self._fail("no code returned from GitHub.")
            return
        try:
            req = urllib.request.Request(
                f"https://api.github.com/app-manifests/{code}/conversions",
                method="POST",
                headers={"Accept": "application/vnd.github+json",
                         "User-Agent": "barkpark-app-bootstrap"},
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                data = json.loads(r.read())
        except Exception as e:  # noqa
            self._fail(f"conversion failed: {e}")
            return
        RESULT["creds"] = data
        RESULT["done"] = True
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(
            b"<!doctype html><body style='font-family:system-ui;max-width:40rem;"
            b"margin:4rem auto'><h1>App created.</h1><p>Credentials captured. You can "
            b"close this tab and return to the terminal.</p></body>")

    def _fail(self, msg):
        RESULT["error"] = msg
        RESULT["done"] = True
        self.send_response(500)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(f"<body><h1>Failed</h1><p>{msg}</p></body>".encode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="App name (globally unique on GitHub)")
    ap.add_argument("--webhook-url", required=True)
    ap.add_argument("--out", required=True, help="where to write the creds JSON")
    ap.add_argument("--port", type=int, default=8724)
    ap.add_argument("--org", default=None, help="create under this org instead of your user")
    args = ap.parse_args()

    redirect_url = f"http://localhost:{args.port}/callback"
    # User apps: github.com/settings/apps/new ; org apps: .../organizations/<org>/settings/apps/new
    create_url = (
        f"https://github.com/organizations/{args.org}/settings/apps/new?state={STATE}"
        if args.org else
        f"https://github.com/settings/apps/new?state={STATE}"
    )
    manifest = build_manifest(args.name, args.webhook_url, redirect_url)

    with socketserver.TCPServer(("127.0.0.1", args.port), Handler) as httpd:
        httpd.create_url = create_url
        httpd.manifest = manifest
        url = f"http://localhost:{args.port}/"
        print(f"\n  Open this in a browser (logged in as the App owner):\n\n    {url}\n")
        print("  → click 'Create GitHub App', then install it on FRIKKern/barkpark.\n")
        try:
            webbrowser.open(url)
        except Exception:
            pass
        while not RESULT["done"]:
            httpd.handle_request()

    if RESULT["error"]:
        print(f"ERROR: {RESULT['error']}", file=sys.stderr)
        sys.exit(1)

    c = RESULT["creds"]
    out = {
        "app_id": str(c["id"]),
        "slug": c.get("slug"),
        "private_key": c["pem"],
        "webhook_secret": c["webhook_secret"],
        "client_id": c.get("client_id"),
        "html_url": c.get("html_url"),
    }
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(out, f, indent=2)
    print(f"  App '{out['slug']}' created (id {out['app_id']}).")
    print(f"  Creds written to {args.out} (chmod 600).")
    print(f"  App page: {out['html_url']}")
    print("\n  NEXT: get the Installation ID after you install it —")
    print("    gh api /users/FRIKKern/installations 2>/dev/null || \\")
    print("    gh api app/installations --jq '.[].id'  # (needs a JWT; easier: the install URL shows it)")


if __name__ == "__main__":
    main()
