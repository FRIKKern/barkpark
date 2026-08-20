# GUI spike externals — KasmVNC .deb + claude-desktop Linux distribution — 2026-07-28 (wave verifier: v-gui-externals)

**Both procurement holes are CLOSED — and a third one opened: `cx33` cannot be created.**

## (a) KasmVNC noble/amd64 .deb — PRESENT

`kasmtech/KasmVNC` latest release is **v1.4.0**, published `2025-10-22T18:47:14Z`, 40 assets,
including a first-class Ubuntu 24.04 (noble) build for both arches. The TigerVNC+noVNC
fallback is **not needed**.

```
kasmvncserver_noble_1.4.0_amd64.deb  2254804 B
  https://github.com/kasmtech/KasmVNC/releases/download/v1.4.0/kasmvncserver_noble_1.4.0_amd64.deb
kasmvncserver_noble_1.4.0_arm64.deb  2236096 B
  https://github.com/kasmtech/KasmVNC/releases/download/v1.4.0/kasmvncserver_noble_1.4.0_arm64.deb
```

Noble assets also exist on v1.3.2 / v1.3.3 / v1.3.4 (pin fallback). No newer prerelease.

## (b) claude-desktop for Linux — OFFICIAL, apt repo AND direct .deb

Anthropic ships an official (beta) Linux desktop app. Canonical doc:
`https://code.claude.com/docs/en/desktop-linux`. Requirements quoted verbatim:
*"Ubuntu 22.04 or later, or Debian 12 or later"* / *"x86_64 or arm64"* — noble qualifies.

Signing key + repo line, verbatim from the doc (both verified live):

```bash
sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc https://downloads.claude.ai/claude-desktop/key.asc
echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list
sudo apt update && sudo apt install claude-desktop
```

Key fingerprint per the doc: `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`.
Repo `Release`: `Origin: Anthropic`, `Suite: stable`, `Codename: stable`,
`Architectures: amd64 arm64`, `Components: main`, dated `Fri, 24 Jul 2026 17:03:57 +0000`.
Newest amd64 package at check time: **`claude-desktop_1.24012.9_amd64.deb`**, 166 243 212 B,
`Installed-Size: 522773` (≈511 MiB), SHA256 `302e6d208dd8c8e9e52067daa28ef3b1171a1613586fd0e10bedc642225b6ee1`.

There is **no postinst-URL scraping to do** — the order can name the apt repo directly.

**Two facts the spike must design around, both from the official doc:**
- *"**Computer Use**: app and screen control isn't available on Linux."* — a KasmVNC kiosk gets
  a human-drivable GUI, not an agent-drivable one.
- *"Desktop doesn't accept a Claude Console API key directly"* — sign-in is claude.ai
  subscription or org SSO only. First-run auth is an interactive browser handshake inside the
  VNC session; there is no headless credential path.
- Depends pull the full GTK/Electron stack incl. `xdg-desktop-portal` +
  `xdg-desktop-portal-gtk|gnome|kde`; Recommends include `qemu-system-x86`, `ovmf`, `virtiofsd`.

## (c) BLOCKER the order must absorb: `cx33` is unbuildable

`cx33` (server-type id 115) is in **zero** datacenters' `server_types.available` list — fsn1-dc14,
nbg1-dc3, hel1-dc2, ash-dc1, hil-dc1, sin-dc1 all exclude it. So does `cpx31`. No `cx*` and no
arm64 type is available in fsn1-dc14 at all. Cheapest currently-creatable x86 substitutes (fsn1):

| type | spec | EUR/hr | EUR/mo |
|---|---|---|---|
| cpx22 | 2c / 4G / 80GB | 0.0312 | 19.49 |
| cpx32 | 4c / 8G / 160GB | 0.0569 | 35.49 |
| ccx13 | 2c / 8G / 80GB (dedicated) | 0.0689 | 42.99 |

A 1-day spike on **cpx32** costs ≈ **EUR 1.37**. Write `cpx32`, not `cx33`, into the order.

## Re-derivation

| Claim | Result | Re-derivation command |
|---|---|---|
| KasmVNC noble amd64 .deb exists on latest | v1.4.0, 2254804 B | `curl -s https://api.github.com/repos/kasmtech/KasmVNC/releases/latest \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['tag_name'],d['published_at']);[print(a['name'],a['size'],a['browser_download_url']) for a in d['assets'] if 'noble' in a['name']]"` |
| That asset URL actually resolves | HTTP 200 | `curl -sIL -o /dev/null -w '%{http_code}\n' https://github.com/kasmtech/KasmVNC/releases/download/v1.4.0/kasmvncserver_noble_1.4.0_amd64.deb` |
| Anthropic apt repo is live + signed | key.asc HTTP 200, PGP block | `curl -sI -o /dev/null -w '%{http_code}\n' https://downloads.claude.ai/claude-desktop/key.asc; curl -s https://downloads.claude.ai/claude-desktop/key.asc \| head -1` |
| Repo publishes claude-desktop amd64 | 18 versions, newest 1.24012.9 | `curl -s https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages \| grep -E '^(Package\|Version\|Filename\|Installed-Size\|Depends):'` |
| The pool .deb downloads | HTTP 200, 166243212 B | `curl -sI https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_1.24012.9_amd64.deb \| grep -iE '^(HTTP\|content-length)'` |
| Repo metadata is Anthropic-origin, amd64+arm64 | Origin: Anthropic | `curl -s https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/Release \| grep -iE '^(Origin\|Suite\|Architectures\|Components\|Date):'` |
| arm64 index exists too | HTTP 200 | `curl -sI -o /dev/null -w '%{http_code}\n' https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-arm64/Packages` |
| cx33 available nowhere | `[]` | `TOK=<fleet hcloud token>; curl -s -H "Authorization: Bearer $TOK" https://api.hetzner.cloud/v1/datacenters \| python3 -c "import sys,json;d=json.load(sys.stdin);print([dc['name'] for dc in d['datacenters'] if 115 in dc['server_types']['available']])"` |
| cx33 is server-type id 115 | id 115, x86, deprecated=False | `curl -s -H "Authorization: Bearer $TOK" 'https://api.hetzner.cloud/v1/server_types?per_page=100' \| python3 -c "import sys,json;[print(s['id'],s['name'],s['architecture'],s['deprecated']) for s in json.load(sys.stdin)['server_types'] if s['name'] in ('cx33','cpx31','cpx32')]"` |

Token note (PDF-D75): the fleet token lives in `~/.config/hcloud/cli.toml` under context
`barkpark`; export `HCLOUD_TOKEN` explicitly — the active context on this Mac is `main`
(guerrilla). Server-type availability is project-independent, so the guerrilla token returns
the same answer.
