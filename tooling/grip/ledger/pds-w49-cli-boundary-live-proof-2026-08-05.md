# PDS wave 49 — CLI distribution boundary, L1 live proof (2026-08-05)

Verifier: cli-boundary-live-proof. No commits, no bp mutations. This file is a
re-derivation recipe only; Decide commits it.

## What was proven, and how to re-derive it

### 1. The installer works and pins cli-v1.16.0 (L1, ran)

    export BARKPARK_BIN_DIR=$(mktemp -d)
    curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
    "$BARKPARK_BIN_DIR/bp" --version

Observed 2026-08-05: `install-cli: detected darwin/arm64`,
`downloading .../releases/download/cli-v1.16.0/bp-darwin-arm64`,
`checksum OK (2508bf81010ed2b2da940cef6d4a97eede6532a60b89f0632c4f61ac365de7dd)`,
`installed bp 1.16.0`. INSTALL_RC=0.
`bp --version` → `{"build_date":"2026-07-24T09:36:16Z","cli_version":"1.16.0","commit":"1291215"}`

REFUTES the "install-cli curl|sh 404s NOW" premise a second time, at L1.

### 2. The installed binary embeds the PRE-#9603 unconditional banner (L1, ran)

The embedded asset is readable from the shipped binary directly — no
`--dry-run` needed:

    strings -a "$BARKPARK_BIN_DIR/bp" | grep -c "Waiting for API on localhost"   # 0  (main-only marker)
    strings -a "$BARKPARK_BIN_DIR/bp" | grep -c "HEALTH_ATTEMPTS"                # 0  (main-only marker)
    strings -a "$BARKPARK_BIN_DIR/bp" | grep -c "NOT ANSWERING"                  # 0  (main-only marker)
    strings -a "$BARKPARK_BIN_DIR/bp" | grep -c 'Waiting for API\.\.\.'          # 1  (tag marker)
    strings -a "$BARKPARK_BIN_DIR/bp" | grep -B4 "Barkpark is running!"

The last prints, from inside the binary a user just installed:

    # Done
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "============================================"
    echo "  Barkpark is running!"

No `HEALTHY` guard anywhere between the probe loop and that echo. #9603
(93e905913, 2026-08-05 21:52 +0200) landed 12 days AFTER cli-v1.16.0
(1291215107, 2026-07-24 11:31 +0200) and reaches no installed binary.

Repo-side confirmation (offline, pure git):

    diff <(git show cli-v1.16.0:internal/cli/setup/assets/deploy.sh) \
         <(git show origin/main:internal/cli/setup/assets/deploy.sh)

### 3. `bp upgrade` says "up to date" on that stale binary (L1, ran)

    "$BARKPARK_BIN_DIR/bp" upgrade
    # {"current":"1.16.0","latest":"1.16.0","path":"...","updated":false}
    script -q /dev/null "$BARKPARK_BIN_DIR/bp" upgrade
    # bp is up to date (1.16.0)

The claim is TRUE against its own basis (the release feed) and MISLEADING about
the thing the user cares about (the shipped source). Staleness measured:

    git rev-list --count cli-v1.16.0..origin/main -- internal/ cmd/      # 88
    git rev-list --count cli-v1.16.0..origin/main -- internal/cli/       # 61
    git rev-list --count cli-v1.16.0..origin/main -- internal/cli/setup/assets/  # 1

### 4. REFUTED: `bp upgrade` does NOT trust `releases/latest` (L1)

Both siblings are already API-first. `git show cli-v1.16.0:internal/cli/upgrade.go`
carries `latestReleaseVersion` → `latestReleaseVersionAPI` (`/releases?per_page=30`)
with the redirect only as a fallback, and the shipped binary contains the string
`/releases?per_page=30`. The twin's bug is NOT present in the sibling.

Why the fix is still load-bearing, measured today:

    curl -fsSL "https://api.github.com/repos/FRIKKern/barkpark/releases?per_page=30" \
      | sed -n 's/.*"tag_name"[: ]*"\([^"]*\)".*/\1/p' | head -8

→ the first EIGHT entries are all `build-<sha>`; only 15 of the 30 are `cli-v*`.
`curl -sI .../releases/latest` today 302s to `cli-v1.16.0`, so the fallback would
work at this instant — that is a RACE the API path removes, not a redundancy.

### 5. No cadence gate exists

`.github/workflows/cli-release.yml` fires only on `push: tags: ["cli-v*"]` (plus
workflow_dispatch). Nothing measures "shipped CLI source != main". cli-v1.17.0 is
a free version number — unlike the npm crown, this boundary has no immutability
wall.

    git tag -l 'cli-v*' | sort -V | tail -3    # cli-v1.14.0 cli-v1.15.0 cli-v1.16.0
