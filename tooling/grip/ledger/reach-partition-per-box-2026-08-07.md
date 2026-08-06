# Reach partition per box — deploy-reliability wave 7 VERIFY

Taken 2026-08-07 against origin/main = ef77af2748ceda54fdd6e078f71a6e6044b55439 and the
six live Barkpark Cloud boxes. Re-derivation recipes only; no conclusions are stated
here that the commands below do not reproduce.

## R1 — per-box reach probe (the one command that produces the whole partition)

```sh
P='hostname; echo -n "slots_root: "; (test -d /opt/barkpark/.slots && ls /opt/barkpark/.slots | tr "\n" " " || echo NONE); echo; echo -n "agent.token: "; stat -c %y /etc/barkpark/agent.token 2>/dev/null || echo MISSING; echo -n "agent_bin: "; stat -c %y /usr/local/bin/barkpark-agent 2>/dev/null || echo MISSING; echo -n "cpu_cores_in_bin: "; strings -a /usr/local/bin/barkpark-agent 2>/dev/null | grep -c cpu_cores; echo -n "load1_in_bin: "; strings -a /usr/local/bin/barkpark-agent 2>/dev/null | grep -c load1; echo -n "agent_unit: "; systemctl is-active barkpark-agent 2>/dev/null; echo -n "self_update_apply: "; (grep -h SELF_UPDATE_APPLY /opt/barkpark/.env /etc/barkpark/*.env 2>/dev/null | head -1 || echo UNSET); echo; echo -n "go_on_path: "; (command -v go || echo NO); echo -n "go_real: "; (ls /usr/local/go/bin/go 2>/dev/null || echo NO); echo -n "head: "; git -C /opt/barkpark rev-parse --short HEAD 2>/dev/null || echo NOREPO'
for h in 157.180.90.121 91.98.139.58 46.224.19.120 5.75.169.183; do echo "===== $h"; ssh -o ConnectTimeout=12 -i ~/.ssh/barkpark_indx root@$h "$P"; done
```

`load1_in_bin` is the NON-VACUOUS CONTROL: a binary that greps 0 for `cpu_cores` and 0
for `load1` is an ABSENT binary, not an old one. Never read `cpu_cores_in_bin: 0` alone.

`46.225.61.223` (gyl) and `116.203.91.216` (dooodo) FAIL host-key verification against
`~/.ssh/known_hosts:53` and `:54`. They were read with
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`, which does NOT verify host
identity and does NOT persist a key. Any fact sourced from those two boxes is one
authority level weaker than the other four until a human reconciles the keys out of band
(`dr-bl-w5-two-boxes-are-unreachable-or-unreporting`). Do not blind-accept.

## R2 — the RUNNING process env, not the .env file (this is the decisive read)

A `.env` file on disk is not what the BEAM was started with. Read the process:

```sh
ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 \
  'pid=$(systemctl show -p MainPID --value barkpark); tr "\0" "\n" < /proc/$pid/environ | grep -E "SELF_UPDATE|PHX_HOST"'
```

## R3 — control-plane view of the same six boxes (slug ↔ host mapping)

```sh
bp cloud status -o json
```

## R4 — the 503 → permanent-pause chain, on main

```sh
git show origin/main:cloud/lib/barkpark_cloud/workers/autoupdate_rollout_worker.ex | sed -n '125,145p'
git show origin/main:api/lib/barkpark_web/controllers/self_update_controller.ex | sed -n '156,168p'
git show origin/main:api/config/runtime.exs | sed -n '940,950p'
git grep -n 'autoupdate_paused: false' origin/main -- cloud/lib   # the only clearer is the human PATCH verb
```

## R5 — cpu_cores provenance (dates the frozen binaries)

```sh
git log --format='%h %ci %s' -S'cpu_cores' origin/main -- internal/agent | tail -2
```

## R6 — which self-update lane each box can actually take

```sh
git show origin/main:scripts/deploy-rebuild.sh | sed -n '30,40p'   # exits 3 when .slots exists
git show origin/main:scripts/apply-update.sh | grep -c agent       # 0 on main — the reach hole
git show origin/main:internal/cli/cloud/freshen.go | sed -n '94,108p'  # ssh lane, no 503 gate
git show origin/main:deploy/instance-deploy.sh | sed -n '806,832p'  # the donor block
```

## TRAP LOG — checks that lied to me this session, and why

1. **zsh parameter modifiers ate my path.** `git show $s:api/lib/...` in a `for` loop
   under zsh expands `$s:a` as the *absolute-path modifier*, producing
   `/…/<sha>pi/lib/...` and a `routes=0` for every sha — a confident, uniform,
   completely false NEGATIVE. Always brace it: `git show "${s}:api/lib/..."`.
   Verify a loop's first row against the same command run standalone.
2. **`/opt/barkpark/api/.slots` does not exist on ANY box, including guerrilla.**
   The real marker is `/opt/barkpark/.slots` (`deploy/instance-deploy.sh:669`).
   Probing the wrong path returns a uniform `PLAIN` that reads exactly like a
   fleet-wide finding.
