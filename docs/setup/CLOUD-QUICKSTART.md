<!-- doc-tier: human | canonical-for: cloud-quickstart | budget: 1300tok -->
# Cloud Quickstart

The fastest path to a **production** Barkpark — no Elixir, no Postgres, no server of your own. Sign up, subscribe, go live. Minutes, not a setup afternoon.

Barkpark Cloud runs the box, TLS, and upgrades; your instance and data are yours. Want to self-host instead? See [QUICKSTART](QUICKSTART.md).

## 1. Install bp

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

Windows (PowerShell): `irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex`.

## 2. Create your account

```bash
bp signup --email you@example.com    # creates a Cloud account + team, and logs you in
```

`bp signup` stores your session — no separate login needed. Coming back on a new machine? `bp login`.

## 3. Subscribe

Going live is subscription-gated. Two tiers, billed in USD:

| Plan | `--plan` | Price |
|---|---|---|
| Supporter | `supporter` | $69 / mo |
| Support++ | `support_plus` | $499 / mo |

```bash
bp subscribe --plan supporter        # prints a Stripe Checkout URL
```

Open the URL and enter a card. Stripe's signed webhook activates your subscription automatically — there is no follow-up CLI step.

## 4. Go live

```bash
bp go-live --name acme               # provisions a fully-managed Barkpark
```

The subscription gate passes and the provisioner brings up a real server. Watch it land and confirm health:

```bash
bp barkparks                         # your fleet + lifecycle state
bp doctor --name acme                # health-check the instance
```

The live dashboard (fleet · billing · lifecycle, SSE-pushed) is served by Barkpark Cloud — the same view in your browser.

## Bring your own provider

Prefer to provision into your own Hetzner account? Connect it, then launch into it:

```bash
bp provider add hetzner --token <hcloud-token>   # connect your provider
bp launch hetzner --name acme                    # provision a Barkpark into it
```

## Where next

- Host a website on your live instance → `bp sites` (create · list · deployments · env · domain · logs — co-located static hosting; `bp sites --help`)
- All Cloud commands → [`bp` cheatsheet](../cheatsheets/bp.md) · the control plane → [`cloud/README`](../../cloud/README.md)
- Operator setup (Stripe keys, DNS, secrets) → [go-live runbook](../ops/barkpark-cloud-go-live.md)
- Self-host on your own machine → [QUICKSTART](QUICKSTART.md)
