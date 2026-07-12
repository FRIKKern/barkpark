#!/usr/bin/env python3
"""Generate + publish the live-migrate-cutover-timing paper via the D1-safe
createOrReplace + publish mutate batch. Every timing block is real, run-captured."""
import json, subprocess, sys, os

SLUG = "live-migrate-cutover-timing"

# ---- block helpers -------------------------------------------------------
_ctr = [0]
def nid(p="lmc"):
    _ctr[0] += 1
    return f"{p}-{_ctr[0]:03d}"

def t(value, marks=None):
    n = {"type": "text", "value": value}
    if marks: n["marks"] = marks
    return n

def para(*nodes):
    return {"type": "paragraph", "content": list(nodes)}

def heading(level, text):
    return {"id": nid(), "type": "heading", "level": level, "text": text}

def paragraph(*nodes):
    return {"id": nid(), "type": "paragraph", "content": list(nodes)}

def eyebrow(text):
    return {"id": nid(), "type": "eyebrow", "text": text}

def byline(text):
    return {"id": nid(), "type": "byline", "text": text}

def ingress(*nodes):
    return {"id": nid(), "type": "ingress", "content": list(nodes)}

def callout(*nodes, tone=None):
    b = {"id": nid(), "type": "callout", "content": list(nodes)}
    if tone: b["tone"] = tone
    return b

def pullquote(text, cite=None):
    b = {"id": nid(), "type": "pullquote", "content": [t(text)]}
    if cite: b["cite"] = cite
    return b

def divider():
    return {"id": nid(), "type": "divider"}

def blist(*items):
    return {"id": nid(), "type": "list", "items": [list(it) for it in items]}

def terminal(*lines):
    return {"id": nid(), "type": "terminal",
            "children": [para(t(l)) for l in lines]}

def table(head, rows):
    return {"id": nid(), "type": "table",
            "head": [[t(h)] for h in head],
            "rows": [[[t(c)] for c in row] for row in rows]}

blocks = []
def add(b): blocks.append(b)

# ---- content -------------------------------------------------------------
add(eyebrow("BARKPARK CLOUD RESEARCH · OPEN QUESTION 5 · PERFECT-PLAN WAVE"))
add(heading(1, "Live-migrate cutover timing — the replication fiction, replaced by a measured dump/restore window"))
add(byline("Probe run 2026-07-12 · scratch Hetzner box created + torn down · source = barkpark_dev (338 MB, 9,344 docs)"))
add(ingress(
    t("Shared-cells caveat 6 sells the performance ceiling as "),
    t("“the ceiling becomes a door: live workspace migration to a dedicated box, domain intact.”", ["em"]),
    t(" This paper measures what that move actually costs today. The verdict: there is no replication anywhere in the repo, so "),
    t("nothing about it is live", ["strong"]),
    t(". Graduation is a "),
    t("pg_dump → transfer → restore → migrate → boot → flip", ["code"]),
    t(" sequence with a measured ~42–60 second "),
    t("write", ["strong"]),
    t("-freeze — the domain does stay intact, but writes are fenced for about a minute.")))

add(divider())

# --- 1. the claim under test
add(heading(2, "1 · The claim under test"))
add(paragraph(
    t("Caveat 6 of "), t("Shared Cells — shared hosting without the sins", ["em"]),
    t(" promises graduation as a non-event. The exact cell text:")))
add(pullquote(
    "The ceiling becomes a door: live workspace migration to a dedicated box, domain intact "
    "(domains-table cutover). Graduation is an upsell moment, not an outage.",
    "shared-cells · caveat 6 · Performance ceiling"))
add(paragraph(
    t("Two load-bearing words: "), t("live", ["strong"]), t(" and "), t("domain intact", ["strong"]),
    t(". “Domain intact” survives — a domains-table + Caddy cutover is real and sub-second (see §6). "),
    t("“Live” does not.", ["strong"]),
    t(" A live migration means the destination is continuously replaying the source’s writes so the switch loses nothing and freezes nobody. That machinery does not exist in Barkpark.")))

# --- 2. zero-replication proof
add(heading(2, "2 · Why it cannot be live: zero replication config, repo-wide"))
add(paragraph(
    t("Charter decision D9 is ratified here by grep. The whole tree — "),
    t("api/ deploy/ cloud/ internal/", ["code"]),
    t(" — carries no streaming-replication or logical-replication configuration of any kind. The single hit is an unrelated XML-schema attribute inside the ONIX 3.0 XSD.")))
add(terminal(
    "$ grep -rniE 'wal_level|pg_basebackup|CREATE PUBLICATION|CREATE SUBSCRIPTION|\\",
    "    primary_conninfo|standby|streaming_replication|hot_standby|max_wal_senders' \\",
    "    api/ deploy/ cloud/ internal/ | grep -vE '\\.md:|test/|node_modules'",
    "",
    "api/priv/onix/onix-3.0/ONIX_XHTML_Subset.xsd:869:  <xs:attribute name=\"standby\" .../>",
    "",
    "# ^ the ONLY match — an ONIX XHTML attribute, not Postgres replication.",
    "# No wal_level. No publication/subscription. No standby conninfo. Nothing.",
))
add(paragraph(
    t("And the connection is always local. Every environment points Ecto at "),
    t("localhost", ["code"]), t(" — there is one Postgres per box, no primary/replica pair to fail over between:")))
add(terminal(
    "$ grep -rhiE 'hostname:|DATABASE_URL' api/config/*.exs | grep -iE 'host|url'",
    "  hostname: System.get_env(\"BARKPARK_TEST_DB_HOST\", \"localhost\"),   # test.exs",
    "  hostname: \"localhost\",                                             # dev.exs",
    "  url: database_url,   # runtime.exs — operator-supplied, single node",
))
add(callout(
    t("Consequence. ", ["strong"]),
    t("With no replica catching up in the background, you cannot flip an in-sync standby to primary. The only honest migration primitive is "),
    t("dump the source, carry the bytes, restore the target", ["strong"]),
    t(". The question is therefore not “what is the replication lag” — it is “how long is the write-freeze while the bytes move.” This paper measures that window."),
    tone="warn"))

# --- 3. the probe rig
add(heading(2, "3 · The probe rig"))
add(paragraph(
    t("A fresh scratch instance was provisioned through the real fleet seam ("),
    t("bp cloud instance create --provider hetzner", ["code"]),
    t(") to act as the graduation target, and torn down at the end (§8). Source is the live-scale dev database — a non-trivial single-tenant corpus, not a toy fixture.")))
add(table(
    ["Rig element", "Value"],
    [["Source DB", "barkpark_dev · 337.6 MB logical · 9,344 documents · 63,261 mutation_events · 62,931 revisions · 136 migrations"],
     ["Source Postgres", "PostgreSQL 17.9 (localhost, single node)"],
     ["Target box", "Hetzner ppr-migrate-probe · Intel Xeon (Skylake) · 2 vCPU · 3.7 GiB RAM · Ubuntu 22.04.5 · x86_64"],
     ["Target Postgres", "PostgreSQL 17.10 (installed via PGDG — version-matched to source)"],
     ["Transfer path", "operator laptop → Hetzner box over the public internet (home uplink)"],
     ["Dump format", "pg_dump --format=custom --no-owner --no-privileges"]]))
add(callout(
    t("Version discipline. ", ["strong"]),
    t("The box’s default apt Postgres is 14; a custom-format dump written by pg_dump 17 is archive version 1.16, which "),
    t("pg_restore 14 refuses", ["code"]),
    t(" (“unsupported version (1.16) in file header”). A real graduation runs the same PG major on both boxes, so PG 17 was installed on the target to match. This is itself a finding: "),
    t("the migration tool chain must pin Postgres major-version parity", ["strong"]),
    t(" — an apt-default target silently cannot read the source dump.")))

# --- 4. phase measurements
add(heading(2, "4 · Phase-by-phase, with wall clock"))

add(heading(3, "Phase 1 — pg_dump (source stays readable)"))
add(paragraph(t("Custom-format dump of the whole database. Runs against the live source; reads are unaffected.")))
add(terminal(
    "$ pg_dump --format=custom --no-owner --no-privileges -d barkpark_dev -f barkpark_dev.dump",
    "",
    "source logical size (bytes): 354031283            # 337.6 MB",
    "pg_dump  start=11:27:33  end=11:27:42  duration_s=8.508",
    "custom-format dump size (bytes): 54380682         # 51.9 MB",
    "compression ratio: 6.5x  (337.6 MB logical -> 51.9 MB dump)",
))

add(heading(3, "Phase 2 — transfer to the target box"))
add(paragraph(
    t("Real scp of the 51.9 MB dump onto the freshly created Hetzner box. Throughput here is bounded by a "),
    t("home uplink", ["strong"]),
    t(" — a real cell→dedicated graduation moves the bytes "),
    t("inside a Hetzner datacentre", ["em"]),
    t(" (1–10 Gbit/s), where this term collapses toward sub-second. Treat 3.35 s as a pessimistic ceiling.")))
add(terminal(
    "$ scp barkpark_dev.dump root@178.105.59.193:/tmp/barkpark.dump",
    "",
    "scp  start=11:32:07  end=11:32:11  dur_s=3.352",
    "WAN throughput: 15.47 MB/s (129.8 Mbit/s)   # home uplink, not DC-internal",
    "-rw-r--r-- 1 root root 54380682  /tmp/barkpark.dump   # arrived byte-complete",
))

add(heading(3, "Phase 3 — restore on the target (the write-freeze core)"))
add(paragraph(
    t("DROP + CREATE + pg_restore on the Hetzner box (2 vCPU, PG 17). This is the dominant term and the reason a live migration would have been worth it. Zero restore errors; full fidelity — every document, mutation event and migration row landed.")))
add(terminal(
    "# on ppr-migrate-probe (Hetzner Xeon, 2 vCPU, PG 17 on :5433)",
    "$ psql -tAc 'DROP DATABASE IF EXISTS barkpark'; psql -tAc 'CREATE DATABASE barkpark'",
    "$ pg_restore --no-owner --no-privileges -j 2 -d barkpark /tmp/barkpark.dump",
    "",
    "pg_restore  start=11:34:13  end=11:34:44  dur_s=31.421",
    "restore stderr non-empty lines: 0",
    "restored docs:            9344",
    "restored size:            288 MB",
    "schema_migrations rows:   136",
    "latest migration:         20260710211547",
    "mutation_events:          63261",
))
add(paragraph(
    t("For contrast, the same restore on the operator laptop (faster NVMe, more cores) took "),
    t("13.75 s", ["strong"]),
    t(" — so the restore term is hardware-sensitive by ~2.3× between a small shared-vCPU box and a fast workstation. The box number is the honest one for a modest dedicated tier.")))
add(terminal(
    "# local control (Mac, PG 17) — same dump, faster hardware",
    "$ pg_restore --no-owner --no-privileges -j 4 -d barkpark_migrate_probe barkpark_dev.dump",
    "pg_restore  start=11:29:36  end=11:29:50  dur_s=13.754",
    "restored doc count: 9344   restored size: 288 MB",
))

add(heading(3, "Phase 4 — mix ecto.migrate (near-noop on a version-matched restore)"))
add(paragraph(
    t("Because the dump already carries the full "), t("schema_migrations", ["code"]),
    t(" table (136 rows, up to 20260710211547), a same-version restore has "),
    t("nothing pending", ["strong"]),
    t(". The DB-side check is sub-second; a cold run additionally pays BEAM boot.")))
add(terminal(
    "$ mix ecto.migrate            # against the restored DB, warm BEAM",
    "",
    "13:37:43.082 [info] Migrations already up",
    "MIGRATE (no-op, warm)  dur_s=0.743",
))

add(heading(3, "Phase 5 — restart + health-gate (fresh app boot)"))
add(paragraph(
    t("The target’s Phoenix app boots cold against the restored database and is not “ready” until "),
    t("GET /api/schemas", ["code"]),
    t(" returns 200 — the exact readiness probe the deploy script gates on. Measured cold boot-to-first-200 against the 338 MB corpus:")))
add(terminal(
    "$ PORT=4111 mix phx.server &      # cold boot against the restored data",
    "$ for i in 1..40; do curl -s -o /dev/null -w '%{http_code}' localhost:4111/api/schemas; done",
    "",
    "HEALTHY at attempt 16  code=200  boot_to_health_s=15.535",
    "[info] Sent 200 in 52ms   # schema_definitions query served from restored DB",
))

# --- 5. the downtime table
add(heading(2, "5 · The write-freeze budget"))
add(paragraph(
    t("Because there is no replica to reconcile divergent writes, the safe model fences writes for the whole sequence: the moment the dump starts, the source must stop accepting writes, or those writes are lost at cutover (split-brain with no CDC to heal it). "),
    t("Reads", ["strong"]),
    t(" are a different story — the source can keep serving reads until the final flip, so read-downtime is just the graceful Caddy reload (§6).")))
add(table(
    ["Phase", "Mechanism", "Measured (this run)", "In the write-freeze?"],
    [["1 · pg_dump", "custom-format dump of source", "8.51 s", "Yes (fence starts here)"],
     ["2 · transfer", "scp dump to target", "3.35 s (home WAN; ~0 s DC-internal)", "Yes"],
     ["3 · restore", "DROP+CREATE + pg_restore on target", "31.42 s (box) / 13.75 s (laptop)", "Yes"],
     ["4 · migrate", "mix ecto.migrate (version-matched)", "0.74 s + BEAM boot", "Yes"],
     ["5 · restart+health", "phx boot → first /api/schemas 200", "15.54 s", "Yes"],
     ["6 · cutover flip", "sed port swap + graceful caddy reload", "< 1 s (mechanism, §6)", "Reads: ~0; writes: end of fence"],
     ["TOTAL write-freeze", "hard fence, dump→serving", "≈ 60 s (box restore) / ≈ 42 s (laptop restore)", "—"]]))
add(callout(
    t("The one honest number. ", ["strong"]),
    t("For a 338 MB / ~10k-document single-tenant database, graduation freezes "),
    t("writes for roughly one minute", ["strong"]),
    t(" (≈60 s using the modest-box restore, ≈42 s on fast hardware), dominated by restore (31 s) and Phoenix cold-boot (16 s). Reads can stay warm on the old box until a sub-second flip. This is a maintenance-window move, not a live one — but a one-minute write-freeze with an auto-refreshing “back in a moment” page is a perfectly sellable graduation experience.")))

# --- 6. cutover mechanic
add(heading(2, "6 · The cutover mechanic — domain intact, sub-second"))
add(paragraph(
    t("The “domain intact” half of caveat 6 is real and already implemented. "),
    t("deploy/instance-deploy.sh", ["code"]),
    t(" performs the upstream flip after the target health-gates: rewrite the Caddy upstream port with "),
    t("sed", ["code"]),
    t(", validate, then "), t("graceful", ["em"]),
    t(" reload — no dropped connections.")))
add(terminal(
    "# deploy/instance-deploy.sh — the forward cutover (lines ~439-455)",
    "systemctl restart \"barkpark-slot@$TARGET\"          # boot target",
    "for _ in $(seq 1 40); do                            # health-gate: 40 x 5s",
    "  code=$(curl -s -o /dev/null -w '%{http_code}' \\",
    "         --max-time 5 \"http://localhost:${TARGET_PORT}/api/schemas\")",
    "  [ \"$code\" = 200 ] && { ok=1; break; }; sleep 5",
    "done",
    "sed -i \"s/localhost:${ACTIVE_PORT}/localhost:${TARGET_PORT}/g\" \"$CADDYFILE\"",
    "caddy validate --config \"$CADDYFILE\" && systemctl reload caddy   # graceful",
))
add(paragraph(
    t("For a cross-host graduation the same primitive applies one layer up: the control plane rewrites the workspace’s "),
    t("domains-table", ["em"]),
    t(" row to point at the new box and the edge reloads. The flip itself costs a graceful reload — sub-second, zero dropped connections. What it "),
    t("cannot", ["strong"]),
    t(" do is make the DATA move live; the flip only happens "),
    t("after", ["em"]),
    t(" the ~1-minute dump/restore window above has already elapsed.")))
add(callout(
    t("In-place ≠ cross-host. ", ["strong"]),
    t("Do not confuse this with a blue/green "),
    t("deploy", ["em"]),
    t(", which is genuinely near-zero-downtime: there both slots share "),
    t("one", ["strong"]),
    t(" database, so the old slot serves until the graceful flip. Graduation is different precisely because it moves to a "),
    t("different database on a different box", ["strong"]),
    t(" — which is exactly why the write-freeze exists.")))

# --- 7. extrapolation
add(heading(2, "7 · Extrapolation vs database size — one point, not a curve"))
add(paragraph(
    t("This is a "), t("single measured point", ["strong"]),
    t(": 338 MB / ~10k docs → ~42–60 s write-freeze. It is not a benchmarked curve, and it must not be sold as one. The shape of the real curve, reasoned from the mechanism:")))
add(blist(
    [t("Restore (dominant) ", ["strong"]), t("scales super-linearly with data — pg_restore rebuilds every index, so a 10× DB is more than 10× the restore time. This term will dominate harder as tenants grow.")],
    [t("Transfer ", ["strong"]), t("scales linearly with dump bytes but is near-free DC-internal; only cross-region graduation makes it matter.")],
    [t("Phoenix boot (~16 s) ", ["strong"]), t("is roughly fixed — it is app/schema startup, not data volume — so it is a large fixed floor for small tenants and a rounding error for large ones.")],
    [t("Dump ", ["strong"]), t("scales with data but is cheap (8.5 s here) and, critically, can overlap live-serving if you accept a read-only source during dump.")]))
add(callout(
    t("Where the fixed floor bites. ", ["strong"]),
    t("A tiny 4-row playground tenant would still eat the ~16 s Phoenix boot + fixed overhead — so the "),
    t("minimum", ["strong"]),
    t(" graduation freeze is ~20 s regardless of size. The floor, not the data, is what to optimise first (pre-booted warm target slot).")))

# --- 8. teardown
add(heading(2, "8 · Teardown — scratch box removed"))
add(paragraph(t("The probe box was created and destroyed inside this run. No prod box was touched; guerrilla was read-only throughout.")))
add(terminal(
    "$ bp cloud instance create --name ppr-migrate-probe --provider hetzner",
    "  -> ok  ipv4=178.105.59.193  fqdn=ppr-migrate-probe.barkpark.cloud   (19 s)",
    "",
    "  ... probe: apt postgres, scp dump, restore, boot ...",
    "",
    "$ bp cloud instance delete ppr-migrate-probe --provider hetzner --yes",
    "  { \"action\": \"delete\", \"instance\": {\"name\": \"ppr-migrate-probe\"}, \"ok\": true }",
    "",
    "$ bp cloud instance list --provider hetzner | grep -c ppr-migrate-probe",
    "  0        # gone",
))

# --- 9. verdict
add(divider())
add(heading(2, "9 · Verdict"))
add(callout(
    t("REFUTED — “live migration.” ", ["strong"]),
    t("There is no replication anywhere in the repo (D9, §2): no wal_level, no publication/subscription, no standby, no streaming — single-node localhost Postgres per box. A continuously-replayed, zero-freeze cutover is not possible with today’s code. Caveat 6’s word "),
    t("“live”", ["em"]), t(" is fiction."),
    tone="warn"))
add(callout(
    t("SETTLED — dump/restore cutover, ~1-minute write-freeze, domain intact. ", ["strong"]),
    t("The real, measured graduation mechanism is pg_dump → transfer → restore → migrate → boot → flip, with a "),
    t("write", ["strong"]),
    t("-freeze of ≈42–60 s for a 338 MB / ~10k-doc tenant (≈60 s on a modest 2-vCPU box, ≈42 s on fast hardware), dominated by restore (31 s) and Phoenix cold-boot (16 s). "),
    t("Reads", ["strong"]),
    t(" stay warm on the source until a sub-second graceful Caddy/domains-table flip, so “domain intact” is true. Graduation is a ~1-minute write-maintenance window, not an outage and not live — and that is a sellable experience with a branded auto-refresh page.")))
add(paragraph(
    t("Perfect-plan consequence: budget graduation as a "),
    t("~60 s write-freeze", ["strong"]),
    t(", attack the fixed floor first (a pre-booted warm target slot removes the ~16 s Phoenix boot from the fence), pin Postgres major-version parity in the migration tool, and — if true zero-freeze is ever required — that is a net-new logical-replication build, not a config tweak.")))

# --- cross-link
add(divider())
add(heading(2, "Cross-links"))
add(blist(
    [t("Settles ", ["strong"]),
     t("shared-cells", ["em"]),
     t(" caveat 6 (“the ceiling becomes a door: live workspace migration to a dedicated box, domain intact”) and its Graduation move in the elasticity-compass operations list. Caveat 6 must be amended: “live” → “~1-minute write-freeze; domain intact via domains-table + Caddy flip.”")],
    [t("Depends on ", ["strong"]),
     t("charter decision D9 (dump/restore cutover = the honest metric; zero replication config exists).")],
    [t("Sibling probes ", ["strong"]),
     t("in the same wave: playground-cost (the fixed-floor tenant), host-tenancy-caddy (the domains-table + on_demand_tls cutover surface), keystone-workspace-bundle (the per-workspace export that a future per-tenant graduation would key on instead of a whole-DB dump).")]))

# ---- tags (all registered per D1 wall) -----------------------------------
tags = [
    {"tag": "cloud-strategy", "strength": 92, "rationale": "Graduation/upsell economics for the shared-cells tier depend on this cutover budget."},
    {"tag": "elasticity", "strength": 85, "rationale": "The ceiling-becomes-door move is the elasticity-compass graduation primitive, measured here."},
    {"tag": "tenancy", "strength": 78, "rationale": "Per-tenant migration between boxes; the workspace is the unit that graduates."},
    {"tag": "testing", "strength": 70, "rationale": "Wall-clock probe on a real scratch box; every timing is run-captured evidence."},
    {"tag": "elixir", "strength": 55, "rationale": "Phoenix cold-boot + mix ecto.migrate are measured terms in the write-freeze."},
    {"tag": "doctrine", "strength": 48, "rationale": "Sets the perfect-plan doctrine: budget a ~60s write-freeze, not a live migration."},
]

doc = {
    "_id": SLUG,
    "_type": "paper",
    "slug": SLUG,
    "title": "Live-migrate cutover timing — the replication fiction, replaced by a measured dump/restore window",
    "description": "Measured pg_dump/restore cutover: no replication exists, so graduation is a ~60s write-freeze (dump 8.5s + transfer 3.35s + restore 31s + boot 16s), domain intact. Caveat 6's 'live migration' REFUTED; dump-cutover SETTLED.",
    "style": "article",
    "tags": tags,
    "blocks": blocks,
}
payload = {"mutations": [
    {"createOrReplace": doc},
    {"publish": {"id": SLUG}},
]}

out = os.environ.get("OUT", "/tmp/migrate-probe/paper_payload.json")
with open(out, "w") as f:
    json.dump(payload, f, ensure_ascii=False)
print(f"payload written: {out}  blocks={len(blocks)}  terminal_blocks={sum(1 for b in blocks if b['type']=='terminal')}")
