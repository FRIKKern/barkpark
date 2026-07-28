# P2 reconciled — one executable recipe: real spend row, key never kept, honest-stamp demo — 2026-07-28 (wave verifier: v-p2-recipe)

**VERDICT: the trilemma dissolves. The order MUST flow the listener path (only `do_order` →
`record_spend` writes spend.jsonl); the key reaches that path via a runtime systemd drop-in on
the /run tmpfs (`Environment=` in a drop-in UNIONS with `EnvironmentFile=` — same-name override
only, proven from the systemd manual, rehearsed on-box with a dummy var before any secret
moves); the same order demos honest stamping if F1's fleet-run.sh has been refreshed onto the
box first (boxes never auto-update the runner). The inline-SSH pattern (stranded R5) is BANNED
for P2: it bypasses `record_spend` and proves nothing.**

**Two consoles, by necessity (access inversion):** every on-box leg runs from the OWNER-GATED
CP-host SSH session (this Mac holds no `barkpark_indx`); the Mac does only ledger-side legs
(task create, task get, roster reads).

**RULING — the var is `ANTHROPIC_API_KEY`,** a FRESH Anthropic Console key minted for this turn
and REVOKED after it. It is the shipped seam (keyVar in `supportAgentPackages`, the unit's
header comment, and the printed hand-over one-liner all name it), it yields a `total_cost_usd`
that corresponds to real metered billing (the telemetry deliverable — Console usage is the
independent cross-check), and it is revocable, which upgrades "never kept" to "provably dead."
`CLAUDE_CODE_OAUTH_TOKEN` is rejected: it ties the box to a personal subscription, its cost is
modeled not billed, and it deviates from every shipped custody surface.

**PROOF CRITERION (load-bearing):** a spend.jsonl row is NOT proof of a real turn. The claude
branch of `record_spend` has NO class-cost fallback — a failed turn still appends a row with
`"cost_usd": null, "source": "claude-cli-json"`. P2 passes ONLY on a row with **numeric**
`cost_usd` whose `order_id` matches the dispatched task, corroborated by the raw JSON receipt
at `/tmp/fleet-run/<task-id>-<worker>/claude.log` (survives until the same ID re-runs; the
`rm -rf` is per-order at claim time). A null-cost row is a red finding, not a pass.

## The sequence

0. **Preconditions** (CP-host session): read `/etc/barkpark/fleet-listener.env` →
   `FLEET_WORKER`, `BARKPARK_API_URL`, `FLEET_AGENT=claude`; baseline
   `grep -c 'ANTHROPIC_API_KEY\|OPENAI_API_KEY' /etc/barkpark/fleet-listener.env` (a pre-existing
   key changes the custody story — record, don't overwrite); baseline
   `wc -l /root/.barkpark-fleet/$FLEET_WORKER/spend.jsonl`. **If F1 has merged:** refresh the
   runner — `curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/tooling/fleet/fleet-run.sh -o /opt/barkpark-fleet/fleet-run.sh && systemctl restart barkpark-fleet-listener`
   (provision-time `fetch()` is the only installer; existing boxes run the old script forever).
1. **Rehearse the merge with a DUMMY var** (no secret): write
   `/run/systemd/system/barkpark-fleet-listener.service.d/99-p2-key.conf` (umask 077) containing
   `[Service]\nEnvironment=FLEET_P2_PROBE=1`, `systemctl daemon-reload && systemctl restart
   barkpark-fleet-listener`, then
   `PID=$(systemctl show -p MainPID --value barkpark-fleet-listener); tr '\0' '\n' < /proc/$PID/environ | grep -E '^(FLEET_WORKER|FLEET_P2_PROBE)='`
   — BOTH lines must print (union proven live on this box's systemd).
2. **Inject** — key via stdin, never argv, never history:
   `ssh root@<box> 'umask 077; printf "[Service]\nEnvironment=ANTHROPIC_API_KEY=%s\n" "$(cat)" > /run/systemd/system/barkpark-fleet-listener.service.d/99-p2-key.conf; systemctl daemon-reload; systemctl restart barkpark-fleet-listener' < <local-keyfile>`
   (/run is tmpfs: RAM-backed, zero persistent-disk contact).
3. **Dispatch from the Mac** on the SAME ledger+scope the box polls (confirm scope on-box:
   `bp task ready` under the box's env context): file one `type:task` per the
   fleet-protocol.md order contract — `assignee=$FLEET_WORKER`, a rich-text `brief` (the field
   helper reads `content.brief.blocks`, NOT description) carrying `FENCE: fleet/p2-proof` +
   `CLASS: light` + a trivial absolute-path file-write order, exactly ONE
   `acceptance_criteria` entry (criterion-less orders make the stamp 409 silently), `--publish`.
   Mirror the document shape of a prior real order (`bp doc get task <old-order>`).
4. **Harvest**: `tail -1` the spend ledger (numeric `cost_usd`, matching `order_id`); `cat` the
   claude.log receipt; `bp task get <id>` from the Mac — stamp evidence quotes the receipt if
   F1 landed, or reads the canned sentence if not (quote it: live PDS-D287 violation — one
   order, two proofs either way).
5. **Remove**: `rm -rf /run/systemd/system/barkpark-fleet-listener.service.d && systemctl
   daemon-reload && systemctl restart barkpark-fleet-listener`.
6. **Absence proof** (quote all outputs):
   `grep -c 'ANTHROPIC_API_KEY\|sk-ant' /etc/barkpark/fleet-listener.env` → 0 (file never touched);
   `ls /run/systemd/system/barkpark-fleet-listener.service.d 2>&1` → No such file or directory;
   `systemctl show barkpark-fleet-listener -p Environment --value` → empty;
   `PID=$(...MainPID...); tr '\0' '\n' < /proc/$PID/environ | grep -c ANTHROPIC` → 0.
   Residue sweep (ON-BOX-VERIFY): `grep -rl 'sk-ant' /root/.claude.json /root/.claude 2>/dev/null`
   — the claude CLI is believed to cache an API-key approval record (trailing key chars) in
   `~/.claude.json` (`customApiKeyResponses`); scrub if present. Non-interactive SSH writes no
   `.bash_history`; the key never appeared in argv.
7. **Revoke the key in the Anthropic Console** — converts the caveat from "a window existed" to
   "a window existed and the key is now dead," and the Console usage line is the independent
   billing cross-check for spend telemetry.

**Fallback** (only if step 1 fails on this box's systemd): append→restart→order→
`sed -i '/ANTHROPIC_API_KEY/d' /etc/barkpark/fleet-listener.env`→restart→same absence proof,
with the weaker caveat (key touched persistent disk; a sed rewrite does not erase old blocks or
the filesystem journal; revocation becomes mandatory, not belt-and-suspenders).

**The honest caveat sentence for the wave paper:** "For the ~N minutes of the P2 turn the
ANTHROPIC_API_KEY existed on the box in RAM only — a root-0600 drop-in on the /run tmpfs and
the listener process environment; it never touched persistent disk, but during that window
root, the hypervisor, or any snapshot of the box could have captured it; the key was revoked in
the Anthropic Console immediately after the turn, so even a captured copy is dead — 'never
kept' means no live credential and no persistent-storage trace remain, not that the key was
never present." (D94's never-keeps is CP-scoped law and is untouched — the CP writes nothing
here; this box-side discipline is the wave's own stricter promise.)

| Claim | Result | Re-derivation command |
|---|---|---|
| Only `do_order`→`record_spend` writes spend.jsonl; ledger path is `${FLEET_HOME:-$HOME/.barkpark-fleet}/${WORKER}/spend.jsonl` | confirmed (fleet-run.sh:66, 135, 235) | `git show origin/main:tooling/fleet/fleet-run.sh \| sed -n '60,70p;130,215p'` |
| A failed claude turn still writes a row — `cost_usd` stays `None` (no CLASS_COST fallback in the claude branch) | confirmed | `git show origin/main:tooling/fleet/fleet-run.sh \| sed -n '140,205p'` |
| Listener env comes ONLY from `EnvironmentFile=/etc/barkpark/fleet-listener.env`; provider keys are developer-appended, never provisioner-written | confirmed | `git show origin/main:deploy/systemd/barkpark-fleet-listener.service` |
| The shipped key var for claude is `ANTHROPIC_API_KEY` | confirmed (cloud_support_cmd.go:138, 771) | `git show origin/main:internal/cli/cloud_support_cmd.go \| grep -n keyVar` |
| Boxes never auto-update fleet-run.sh (provision-time `fetch()` only) | confirmed (cloud_support_cmd.go:1445-1448) | `git show origin/main:internal/cli/cloud_support_cmd.go \| sed -n '1440,1450p'` |
| `EnvironmentFile=` overrides `Environment=` only for the SAME variable → a drop-in var absent from the file merges (union) | manual verbatim: "Settings from these files override settings made with Environment=." | `curl -s https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.exec.xml \| grep -A2 'Settings from these files override'` |
| Drop-in `<unit>.d/*.conf` merges after the main unit; /run/systemd/system is on the load path | manual verbatim: "All files with the suffix .conf from this directory will be merged" | `curl -s https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.unit.xml \| grep -B2 -A4 'drop-in'` |
| Canned stamp + unconditional close, both silenced | confirmed (fleet-run.sh:237-239) | `git show origin/main:tooling/fleet/fleet-run.sh \| sed -n '236,240p'` |
