# PDS wave 30 — charter-coverage re-derivation recipe (v7-charter-coverage)

Every row below re-derives from a clean checkout. `git show origin/main:` is the authority;
a worktree read is NOT.

```sh
git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter.md
wc -l /tmp/charter.md                                   # 6888
grep -n 'PDS-D399\|PDS-D401\|PDS-D405\|PDS-D407\|PDS-D412' /tmp/charter.md
```

| # | claim | command | expected |
|---|---|---|---|
| 1 | PDS-D399 is a DUPLICATED number (two unrelated entries) | `grep -n '^- \*\*PDS-D399' /tmp/charter.md` | two hits: 6503 (instrument/sys.path) and 6586 (post-read assumption) |
| 2 | the charter DOES carry the refuted legacy-DNS sentence | `sed -n '6605p' /tmp/charter.md` | ``…they ride the legacy `dns.hetzner.com/api/v1`, `internal/cli/cloud/dns.go:163`…`` |
| 3 | the cited anchor is real but is the WRONG file | `git show origin/main:internal/cli/cloud/dns.go \| sed -n '163p'` | `const hetznerDNSBase = "https://dns.hetzner.com/api/v1"` — the provisioning helper, not the CLI |
| 4 | the 6 CLI dns sites ride INTEGRATED Cloud DNS | `git show origin/main:internal/cli/hetzner_dns_cmd.go \| sed -n '1,13p'` | header says "INTEGRATED Cloud DNS … hcloud-go v2.44" |
| 5 | D405's "hzResDone ×3" is not 3 registry rows | `git show origin/main:internal/cli/success_claim_registry_test.go \| grep -c 'hzResDone('` | `1` |
| 6 | `hzResPost[T]` (charter plan table :6865) never shipped | `git grep -nw 'hzResPost' origin/main -- internal/` | zero hits; shipped names are `hzResDestroyed` / `hzResGoneRead` |
| 7 | bare `hzResGone` is not a symbol | `git grep -nw 'hzResGone' origin/main -- internal/` | zero hits (only the TYPE `hzResGoneRead`, respost.go:95) |
| 8 | D407 contemplates NO live traffic | `sed -n '6730,6752p' /tmp/charter.md \| grep -ni 'live\|localhost\|curl\|guerrilla'` | no output |
| 9 | D407's Elixir anchor still holds | `git show origin/main:api/lib/barkpark_web/controllers/auth_controller.ex \| sed -n '379p'` | `json(conn, %{ok: true})` |
| 10 | D401's "zero single-GET fixtures" is now stale for all 8 kinds | `for k in networks firewalls load_balancers primary_ips floating_ips placement_groups certificates; do echo -n "$k "; git grep -oh "\"/$k/[0-9]*\"" origin/main -- 'internal/cli/*_test.go' \| wc -l; done` | each `2` — but ALL live in `hetzner_respost_test.go`, i.e. DESTROY-shaped only |
