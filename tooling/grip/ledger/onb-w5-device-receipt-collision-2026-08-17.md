<!-- doc-tier: cold | canonical-for: onb-w5-device-receipt-collision-rederive | budget: 400tok -->

# onb-w5 device-receipt/alias micro-fact re-derivation (2026-08-17)

Verifier [device-receipt-collision]. Two one-line lookups for the stacked receipt + alias slices.

## (a) Is the device-receipt slice a clean stack on #12030?

CLEAN STACK. #12030 touches only the poll loop + SaveConfig error wrap; the
emitDeviceLoginSuccess *definition* (origin/main lines 270-285) is untouched.

    gh pr diff 12030 | grep -n '^@@'
    # → last login_device.go hunk: @@ -175,7 +212,11 @@ (old lines 175-181)
    gh pr diff 12030 | grep -n 'emitDeviceLoginSuccess'
    # → only line 180 CALL SITE appears, as an unchanged context line
    git show origin/main:internal/cli/login_device.go | grep -n 'func emitDeviceLoginSuccess'
    # → 270  (definition region ~270-285, outside every #12030 hunk)

## (b) Do fleet rows carry the ID, and does MeResult.Team carry Name/Slug?

YES to both. Barkpark.ID exists (key the alias InstanceID compare on it);
MeResult.Team is *Team{ID,Name,Slug,Role} (receipt can name the team).

    git show origin/main:internal/cloudclient/client.go | sed -n '84,98p'
    # → type Barkpark struct { ID string `json:"id"` ... TeamID ... Team *Team ... }
    git show origin/main:internal/cloudclient/client.go | sed -n '64,68p'
    # → type Team struct { ID; Name; Slug; Role }
    git show origin/main:internal/cloudclient/client.go | sed -n '718,723p'
    # → type MeResult struct { User; Team *Team `json:"team"`; Teams []Team; Role }

CAVEAT: MeResult.Team is nil when teamless — receipt must nil-guard.
Barkpark.LastSeenAt (`last_seen_at`) already exists (informs LAST-SEEN slice).
