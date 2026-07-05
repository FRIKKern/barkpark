<!-- doc-tier: human | canonical-for: service-level-agreement | budget: 900tok -->

# Barkpark Cloud — Service Level Agreement

This SLA applies to the **hosted/managed Barkpark Cloud** offering. Self-hosted
deployments run on infrastructure you control, so this commitment does not apply
to them — but the same status page and incident tooling ship with the open
source, so you can publish your own.

Live status: **`/status`** (human) and **`/status.json`** (machine-readable, for
your uptime monitors).

## Uptime commitment

- **Target: 99.9% monthly uptime** of the HTTP API (`/v1/*`), measured as the
  percentage of one-minute intervals in a calendar month during which the API
  returns non-`5xx` responses to valid requests.
- "Downtime" excludes: scheduled maintenance announced ≥48h in advance on the
  status page; disruption caused by factors outside our reasonable control
  (force majeure, upstream network/DNS providers); and misuse or requests that
  violate the acceptable-use terms.

## Service credits

If monthly uptime falls below target, eligible accounts may request a credit
against the following month's fees:

| Monthly uptime | Service credit |
|---|---|
| < 99.9% | 10% |
| < 99.0% | 25% |
| < 95.0% | 50% |

The credit schedule is the single source of truth in `config :barkpark, :sla`,
so the status page, the JSON API, and this document never drift.

## Claiming a credit

Open a request within 30 days of the affected month, citing the incident(s) from
the status page's incident history. Credits are applied to future invoices and
are the exclusive remedy for missed uptime.

## Incident communication

Active and past incidents are published on the status page with a lifecycle
(`investigating → identified → monitoring → resolved`) and severity. Major
incidents are posted within 30 minutes of detection.
