<!-- doc-tier: agent | canonical-for: cloud-boundary-rule | budget: 700tok -->
# 0004 — Cloud boundary: sell labor, never hobble self-host

**Status:** Accepted 2026-06-28
**Deciders:** Barkpark core team
**Related:** [../PHILOSOPHY.md](../PHILOSOPHY.md) (prose owner of the stance)

## Context

Barkpark is open-source and self-hostable by design. Barkpark Cloud funds development by
selling convenience. The standing risk is feature creep that quietly degrades the free
self-host path to make Cloud look necessary. This record codifies the rule that prevents it.

## Decision

Every Barkpark Cloud feature must **sell operational labor** and must **never hobble** the
free self-host path. The test is one question:

> **Does this make Barkpark _work_, or only make it _easier to operate_?**

- Makes Barkpark **work** (a content feature, schema type, API capability, or plugin) →
  it ships in the **OSS core first**, free, for everyone.
- Only saves **operational labor** (provisioning, TLS, backups, monitoring, identity across
  instances) → it is a **fair paid upsell** on Cloud.

## Worked examples

| FREE — OSS core | FAIR PAID — Cloud | FORBIDDEN |
|---|---|---|
| Studio, the HTTP API, schemas | Warm-pool instant managed servers | Artificial document / record limits |
| Documents, datasets, all plugins | Automatic TLS + backups + monitoring | Schema types held back from OSS |
| Manual deploy, Docker Compose | Fleet dashboard / one login for every Barkpark | Forced hosted auth |
| `bp doctor`, export/import, custom code | Envoyer/Vapor-style deploy convenience | Forced telemetry |

Studio is free. Provision-it-for-me convenience (the Envoyer/Vapor analogue) is fair to
charge for — you pay because it's better, not because the free version is crippled.

## Binding clause

Every new content feature, schema, API capability, or plugin lands in the OSS core first. A
Cloud-only content capability is a violation of this record and must be rejected in review.
