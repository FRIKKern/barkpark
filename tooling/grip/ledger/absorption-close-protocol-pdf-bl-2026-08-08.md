# Absorption close protocol — pdf-bl-limit-env-passthrough (self-host-blessing W1/S1)

Re-derivation recipes. Every line below is a command, not a claim.

## 1. The absorption-map paper carries NO close protocol

    bp doc get paper hobby-hardening-absorption-map -o json \
      | python3 -c "import sys,json,re,html;d=json.load(sys.stdin);doc=d.get('doc',d);print(html.unescape(re.sub(r'<[^>]+>','\n',doc['body_html'])))" \
      | grep -n -iE "absorb|inherit"

Hits: title, the table header `absorbs / inherits`, three row cells, and open question #1
("Absorb-and-close vs cite-only … an epic-etiquette ruling"). Zero mechanics: no worker
identity, no wave_paper rule, no citation form. The paper defers the ruling to the crown.

## 2. The crown paper makes the RULING (not the mechanics)

    bp doc get paper hobby-hardening-capstone -o json \
      | python3 -c "import sys,json,re,html;d=json.load(sys.stdin);doc=d.get('doc',d);print(html.unescape(re.sub(r'<[^>]+>','\n',doc['body_html'])))" \
      | grep -n -iE "absorb|cite-only|pdf-bl"

Line ~1443: "absorb-and-close with a pointer beats a dangling deferred row".
Line ~1473: pdf-bl → "ABSORB into E3-S1 … closes the task by name."

## 3. Charter says the same, still no mechanics

    git show origin/main:.claude/workflows/bp-self-host-blessing-charter.md | sed -n '112p'

(The charter exists on origin/main and NOT in the local checkout — brief from origin.)

## 4. Stored state + byte-exact criterion strings

    bp task get pdf-bl-limit-env-passthrough -o json

claim=null · lifecycle_status=open · execution_class=executable · dependency_count=0 ·
queue_gate=null · parent_id=personal-dev-fleet-epic ·
wave_paper=personal-dev-fleet-wave-mvp0-2026-07-24 · rev=21061afc8f7de44b55685b9593d6ce40 ·
github issue 6065 (FRIKKern/barkpark).

Criterion 0 (byte-for-byte):
All four LIMIT_* keys appear as bare passthrough lines in cloud/docker-compose.yml and are documented in cloud/.env.example

Criterion 1 (byte-for-byte):
grep proof quoted that no other runtime.exs env read is missing from the passthrough allowlist (sweep, not just LIMIT_*)

## 5. Unmet criteria DO block a done close (the manifest help lies)

    bp task close --help | grep -c "Unmet criteria never block a close"   # 1 — the lie
    git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '430,442p'  # the truth

`check_criteria_proven/4` returns `{:error, {:criteria_unmet, indices}}` for a "done" close
with any unmet criterion, unless a criteria override is passed; `cancelled|blocked` are exempt
by name. Filed as `dr-w14-bl-close-help-manifest-lies` (open).

## 6. Therefore the close sequence S1's builder must run

    bp task claim pdf-bl-limit-env-passthrough <worker>     # claim is null; close needs a holder
    bp task close pdf-bl-limit-env-passthrough <worker> <epoch> done \
      "absorbed into self-host-blessing S1 (<PR#>)" \
      --set 'criteria:=[{"index":0,"met":true,"evidence":"…","criterion":"<criterion 0 verbatim>"},
                        {"index":1,"met":true,"evidence":"…","criterion":"<criterion 1 verbatim>"}]'

`criterion` text is REQUIRED on every met=true entry (409 criterion_text_required / 409
criteria_mismatch). If the brief moved under the claim, close 409s doc_changed_since_claim →
re-read and pass `--set observed_rev=<current_rev>`.

## 7. deploy.yml: cloud/.env.example rides the control-plane trigger

    git show origin/main:.github/workflows/deploy.yml | sed -n '10,11p;79p'

on.push.paths line 11: `      - "cloud/**"`
line 79: `          if echo "$changed" | grep -qE '^(cloud|deploy|internal|cmd)/'; then echo "cp=true" >> "$GITHUB_OUTPUT"; else echo "cp=false" >> "$GITHUB_OUTPUT"; fi`

`cloud/.env.example` matches both — it is EXPOSED to the control-plane redeploy. It does not
match the instance regex on line 87 (`^(api|internal|deploy|connectors|templates)/`).
