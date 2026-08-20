<!-- doc-tier: cold | canonical-for: onb-w7-d42-guard-commit-phantom | budget: 600tok -->

# onb-w7 · D42 §1b-guard-commit phantom re-derivation (2026-08-18)

VERIFY V4-premise-smoke-charter. D42 (charter line 90) cites BOTH `1928df610e` and
`f71b1444cb` as §1b release-cadence guard commits for the C2 stamp. `1928df610e` is a
PHANTOM for this purpose: it touches only the setup caddy path, not the guard.

Re-derive (origin/main):

    git show --stat --format= 1928df610e   # -> internal/cli/setup/caddy.go, caddy_test.go  (NO scripts/doctor.sh)
    git show --stat --format= f71b1444cb   # -> scripts/doctor.sh | 40 +++  (the real §1b guard)
    git show --name-only --format= 1928df610e | grep -c scripts/doctor.sh   # -> 0
    git show --name-only --format= f71b1444cb | grep -c scripts/doctor.sh   # -> 1

Consequence for the close: C2 evidence must cite `f71b1444cb` only (arm-D phantom class).
D50 (charter line 103 — the operative close-wording law) does NOT reproduce the phantom;
it cites only the green §1b line. So a Decide that follows D50 (not D42's commit list) is
safe. Stamp C2 as guard-existence-plus-green-§1b-verdict, never "zero drift".

Also flagged this wave: D49/D51 pairing — "SEAL never gates close" is authorized by D51
alone (line 104); D49 (line 102) authorizes only the deploy.sh embed-drift slice.
