# op-gate boundary — re-derivation recipe (wave 19 verify, 2026-08-01)

Answers: is `operator-zero-staging` red at 768 (w17's claim) or clean from 620 up
(w18's claim)? And is `PLATFORM_ADMIN_EMAILS` unset in EVERY running control-plane
container, not just the blue slot?

VERDICT — both filed claims are partly right and the true band is DISCONTINUOUS.
`operator-zero-staging` is red at 320/360/390/430, CLEAN at 600-720, and RED AGAIN
at 740-800, clean from 830. w18 measured only 620/900/1024/1440 and so stepped over
the second red band, which is created by the `@media (max-width: 720px)` shell fold
releasing the sidebar above 720.

## 1. Drive the three operator scenarios (measure origin/main, not the checkout)

The primary checkout is DIVERGED from origin/main (283 commits behind on the cloud
static tree at the time of writing). Measure a detached worktree of origin/main:

    git worktree add --detach /tmp/w19main origin/main
    git -C /tmp/w19main rev-parse HEAD          # expect the origin/main sha

Driver: `scratchpad/opgate-drive.mjs` (CDP machinery lifted verbatim from
`cloud/priv/static/__preview__/overflow-guard.mjs`; asserts served-bytes ==
disk-bytes before measuring, GR125a).

    WIDTHS=320,360,390,430,620,740,768,800,830,900,1024 \
    THEMES=light,dark \
    SCENS=operator-console,operator-halted,operator-zero-staging \
    STATIC_ROOT=/tmp/w19main/cloud/priv/static \
    node scratchpad/opgate-drive.mjs

THE DEEP LINK IS MANDATORY. `?scen=operator-*` alone lands on `#overview` and
`.op-gate` never mounts — the first run of this probe reported ".op-gate never
appeared" six times. The URL must carry the scenario's own `deepLink`:
`?scen=<scen>&theme=<t>#operator`.

Two distinct metrics, do not conflate them:
  - CLIPPED       `pill.scrollWidth > pill.clientWidth`
  - PAINTS-OUTSIDE `label.getBoundingClientRect().right > pill.getBoundingClientRect().right`
    (`.status-pill-label` computes `overflow: visible`, so the glyphs are PAINTED
    outside the capsule rather than clipped — which is why every page-level and
    every text-clip instrument walks past this defect.)

## 2. The mutation bench (no file is edited)

`scratchpad/opgate-mutate.mjs` injects candidate declarations as a runtime
`<style>` and re-measures, so nothing on disk changes:

    STATIC_ROOT=/tmp/w19main/cloud/priv/static node scratchpad/opgate-mutate.mjs

Result that matters for D210: candidate **D — the five-declaration wrap recipe
copied onto `.detail-rail`, `.fleet-status` and `.instance-card-head` — DOES NOT
FIX the fourth host.** Every clipped cell stays clipped (53/36, 53/38, 53/40 at
320); it only removes the paints-outside symptom, i.e. it HIDES the defect.
Candidate A, one declaration `.op-gate .status-pill { flex: 0 0 auto; }`, is
64/64 at every width x every scenario with no page-level overflow anywhere.

## 3. The env re-check (every running control-plane container)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'docker ps -a --format "{{.Names}}\t{{.Status}}";
       for c in $(docker ps --format "{{.Names}}" | grep control_plane); do
         echo "--- $c"; docker exec $c sh -lc "printenv PLATFORM_ADMIN_EMAILS; echo rc=\$?"; done;
       docker inspect cloud-control_plane_blue-1 \
         --format "{{range .Config.Env}}{{println .}}{{end}}" | grep PLATFORM'

Read the `Config.Env` line SHAPE, not just its presence: docker-compose.yml:67
passes `- PLATFORM_ADMIN_EMAILS` (no `=`), so the entry appears in `Config.Env`
as a bare name meaning "inherit from the daemon's env". With the host var unset
the variable is ABSENT inside the container — `printenv` rc=1. An inspect grep
that only checks for the string is a FALSE POSITIVE here.
