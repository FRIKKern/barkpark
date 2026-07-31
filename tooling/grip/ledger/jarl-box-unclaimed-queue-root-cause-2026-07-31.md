# jarl box (91.98.139.58 / warm-97cd5095) — the unclaimed-queue root cause, settled live

Two surveyors derived two root causes from source alone: **token mismatch**
(builder 401-ing on `agent.token`) vs **never installed** (no site plane on the
box). Both are real; they are SEQUENTIAL, not competing. This file is the
re-derivation recipe, run 2026-07-30/31 through the cp-ops workflow.

## Step 0 — the incident window

    bp task get site-builder-worker-unclaimed-queue -o json
    # description: deployment 753fd40b… minted 2026-07-30T16:51Z, queued >10min
    # inserted_at: 2026-07-30T17:13:34Z

## Step 1 — enumerate cp-ops history and map each run to its operation

    gh run list --workflow cp-ops.yml --limit 40 --json databaseId,createdAt,conclusion
    # every run is a workflow_dispatch; the OPERATION is the first tab-column of
    # `gh run view <id> --log` (job-name field) and the inputs are echoed in the
    # step's `env:` block (BOX_IP/UNIT/OP are not secrets).
    gh run view <id> --log | sed 's/^[^\t]*\t[^\t]*\t//' | grep -E '  (BOX_IP|UNIT|OP): '

Total cp-ops history at the time of writing: 24 runs, ALL dated 2026-07-30.
First ever `site-runtime-install` = run 30566402336 @ 17:32:19Z.
First ever `builder-token-fix`    = run 30568614706 @ 18:01:53Z.

## Step 2 — the plane was ABSENT at incident time (primary cause)

    gh run view 30566402336 --log | grep -E 'probe:|install docker|previously unselected'
    # 2026-07-30T17:32:33Z == probe: warm-97cd5095 x86_64 ==
    # 2026-07-30T17:32:33Z == install docker ==
    # 2026-07-30T17:32:40Z Selecting previously unselected package pigz.
    # 2026-07-30T17:33:05Z Created symlink …/barkpark-builder.service → …
    # 2026-07-30T17:33:08Z == site-runtime-install complete ==

Docker was installed **from scratch** at 17:32:33Z — 41 minutes AFTER the
deployment was minted. `git clone` (not fetch) into `/opt/barkpark-tools`, and
the builder unit symlink was *created*, not refreshed. At 16:51Z the box had no
docker, no nixpacks, no builder binary and no unit. `provision-installs-site-plane`
is the primary cause; the task's `muscle-1` guess is dead.

## Step 3 — token mismatch was the SECOND blocker (real, but only after step 2)

    git show origin/main:.github/workflows/cp-ops.yml | sed -n '/builder-token-fix)/,/;;/p'
    # sed -i "s#--token-file /etc/barkpark/agent.token#--token-file /etc/barkpark/worker.token#"

i.e. the unit installed at 17:33 pointed at the AGENT token; `/v1/builder/claim`
authenticates with the CP's shared WORKER_TOKEN. Proof it mattered:

    gh run view 30568849327 --log   # box-file-tail 18:05Z, ls /var/log/barkpark-builder/
    # 0e5bdf1f-b8dc-4c18-8763-713079499a7d.log      <- exactly ONE file
    # barkpark-builder build start ts=2026-07-30T18:02:08Z deployment=0e5bdf1f…

The one and only build the builder ever started began at **18:02:08Z** — the
same second `builder-token-fix` restarted the unit. Between 17:33:05 and
18:02:08 (~29 min, ~350 polls at interval=5s) it claimed nothing.

## Step 4 — the journal shows NO 401s, and structurally cannot

    gh workflow run cp-ops.yml -f operation=box-logs -f box_ip=91.98.139.58 -f unit=barkpark-builder
    gh run view <id> --log
    # Jul 30 17:33:05 warm-97cd5095 systemd[1]: Started Barkpark site builder…
    # Jul 30 17:33:05 barkpark-builder[1281595]: worker=warm-97cd5095 control=https://api.barkpark.cloud platform=linux/arm64 interval=5s
    # … only systemd lifecycle + the startup banner, for 7.5 hours.

Cause in code:

    git show origin/main:internal/builder/builder.go | sed -n '175,186p'
    #   had, err := b.RunOnce(ctx)
    #   if err != nil {
    #     // One bad cycle … does not kill the worker; sleep + retry.
    #     select { case <-ctx.Done(): …; case <-time.After(interval): }
    #     continue        <- err is DISCARDED, never logged

`claim()` returns `statusError(resp)` on a 401 (default arm of the status
switch, builder.go:240) and `Run` swallows it. A token-mismatched builder is
**invisible in journalctl by construction** — this is why box-logs looked
"healthy" while nothing was being claimed. Any watchdog that relies on the
builder reporting its own auth failure is relying on nothing.

## Step 5 — the arch bug, caught live

    # 17:33:05 banner: platform=linux/arm64   on a box probed as x86_64
    # 17:45:40 banner: platform=linux/amd64   (after #8156)
    git log --oneline origin/main -- deploy/site-runtime-install.sh
    # 0be8241f8 worker token kept across reinstalls (#8178)
    # 70e8461a4 adds docker-buildx — nixpacks needs BuildKit (#8175)
    # 50b984367 site-artifact-fetch + arch-correct builder platform (#8156)
    # 74a88d1cd cp-ops site-runtime-install (#8151)

STILL BROKEN on origin/main today:

    git show origin/main:deploy/site-runtime-install.sh | sed -n '37,42p'
    #   if ! $GO version >/dev/null 2>&1; then
    #     curl -sL https://go.dev/dl/go1.24.5.linux-arm64.tar.gz | tar -xz -C /usr/local

Line 41 is arm64-hardcoded. It did NOT abort on jarl's box only because Go
1.24.2 amd64 happened to be preinstalled ("go version go1.24.2 linux/amd64" in
the 17:32 log). On a genuinely fresh cx23 the guard fires and installs an arm64
toolchain — fix before any lane reuses the script.

## Step 6 — the third blocker after the first claim: no buildx

    gh run view 30568849327 --log   # the 18:02 build log
    # ERROR: BuildKit is enabled but the buildx component is missing or broken.
    # Error: Docker build failed

Fixed by #8175. Current state (box-probe 30572835794 @ 18:59Z):

    # == docker ps ==  site-jarl-website-635ca3e3 Up 37 minutes
    # == units ==      active / active / active / active   (agent, builder, runtime, caddy)

## What this settles for the wave

* **Winner: never-installed is the root cause of the filed incident.** Token
  mismatch is real and was the next wall, 40 minutes downstream. Both must be
  paid; the provision lane owns the first, the builder-identity ruling the second.
* The plane took **FOUR** manual cp-ops interventions to stand up (install,
  arch, token, buildx). "Zero manual steps" means all four are provisioning-time.
* The queue-age alarm cannot be delegated to the builder. It must be a
  CP-side read-only query — the builder is silent on every failure mode observed
  here (401 swallowed, buildx failure only in a per-deployment file the CP never
  reads).
