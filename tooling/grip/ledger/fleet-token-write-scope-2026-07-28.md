# Fleet-project hcloud token — WRITE scope? — 2026-07-28 (wave verifier: v-fleet-write-scope)

**VERDICT: YES. The local `barkpark` hcloud context holds a READ-WRITE fleet-project token.**
Proven live by a minimal reversible write on a resource type no code path touches: a
placement group created and deleted, census restored to empty. Corroborated historically by
`task-2fe53a3c0e984eab`'s close_reason — this same credential drove three real teardowns
("box census delta zero each time"). **Decide may authorize a live P1 fire: the janitor path
exists on this Mac.**

## The safety read came first — and it changed the probe

`resolveSSHKey` (`internal/cli/cloud/provider.go:503`) does **not** attach all project keys.
It is by-name/pinned with a conditional fallback:

    if k := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY")); k != "" { return k, nil }
    keys, err := sshKeyLister(ctx)                 // hcloud ssh-key list
    if len(keys) == 1 { return keys[0], nil }
    return "", fmt.Errorf("set BARKPARK_SSH_KEY: found %d ssh keys (need exactly one to auto-select)", len(keys))

The assignment's prescribed ssh-key probe was therefore **rejected as unsafe**. The fleet
project holds **exactly one** key (`barkpark-indx`, id 113176188). Creating a second key
flips the auto-select arm from "use it" to a hard error, so **every provision that runs while
`BARKPARK_SSH_KEY` is unset would fail** for the life of the probe. `Create`
(`provider.go:617`) resolves the key FIRST and returns without creating on a resolution
error — i.e. it fails closed, loudly, but it fails. `cmd/barkpark-provisioner/main.go:128`
states the key vars are "validated lazily", so the provisioner does **not** fail fast at boot
on an unset `BARKPARK_SSH_KEY` — meaning the CP may well be running on the auto-select arm.
This Mac cannot SSH the CP, so which arm is live there is **unknown**.

**STANDING HAZARD for the wave (new):** nobody may add a second ssh-key to the fleet Hetzner
project. It is a one-line, invisible way to break every provision.

## The write probe actually run

Placement groups: zero exist in the project, and no Go/Elixir/shell path creates or selects
one — fully disjoint from provisioning.

| Step | Output |
|---|---|
| before | `ID   NAME   SERVERS   TYPE   AGE` (empty) |
| create | `Placement Group 1799562 created` (rc=0) |
| list | `1799562   verify-scope-probe-DELETE-ME   0 servers   spread   just now` |
| delete | `Placement Group verify-scope-probe-DELETE-ME deleted` (rc=0) |
| after | empty — census delta zero |

Hetzner Cloud API tokens carry ONE project-wide permission (read, or read&write); there is no
per-resource scoping. A successful placement-group create therefore establishes the token is
read&write project-wide, which covers `server delete`. That last step is an **inference from
Hetzner's permission model**, not a directly executed server delete — the only direct proof
would be destroying a live box. The historical evidence in `task-2fe53a3c0e984eab` closes the
gap empirically.

## Janitor path, confirmed executable

`hcloud server delete` takes **names/IDs only — no `--selector` flag**. Delete-by-label is
therefore list-then-delete. Both selector forms answer:

    hcloud --context barkpark server list --selector barkpark-fleet-support -o columns=name -o noheader
    → warm-eabbf4cc            # muscle-1, 46.224.19.120

`scripts/pdf-mvp0-journey-proof.sh` already carries this as `PDFJP_TEARDOWN_HCLOUD_TOKEN` /
`PDFJP_TEARDOWN_HCLOUD_CONTEXT` (default `barkpark`), with `trap cleanup EXIT` installed at
:580 BEFORE any write and a money-safety gate at :866-898 that aborts unless the teardown
credential can see a CP-managed host. That gate will PASS from this Mac.

| Claim | Result | Re-derivation command |
|---|---|---|
| Key selection is by-name/pinned, never all-keys | `--ssh-key sshKey` from `resolveSSHKey` | `git show origin/main:internal/cli/cloud/provider.go \| sed -n '494,535p'` |
| Fleet project holds exactly ONE ssh key | `barkpark-indx` only | `unset HCLOUD_TOKEN; hcloud --context barkpark ssh-key list` |
| Token has WRITE scope | `Placement Group 1799562 created` / `deleted`, census restored | `unset HCLOUD_TOKEN; hcloud --context barkpark placement-group create --name verify-scope-probe-DELETE-ME --type spread && hcloud --context barkpark placement-group delete verify-scope-probe-DELETE-ME` |
| Label census for the janitor works | `warm-eabbf4cc   46.224.19.120` | `unset HCLOUD_TOKEN; hcloud --context barkpark server list --selector barkpark-fleet-support -o columns=name,ipv4 -o noheader` |
| `server delete` has no `--selector` | `Usage: hcloud server delete <server>...` | `hcloud server delete --help` |
| This credential already tore down real boxes | close_reason: "exercised for real three times … box census delta zero each time" | `bp task get task-2fe53a3c0e984eab` |
| Journey-proof carries the raw teardown trap | `trap cleanup EXIT` at :580 | `git show origin/main:scripts/pdf-mvp0-journey-proof.sh \| sed -n '575,585p'` |

## Tooling tripwire found while running the assignment

The wave's prescribed MUST-RUN grep **silently returns nothing**: git's default regex engine
has no `\|` alternation, so `git grep -n 'ssh-key\|SSHKey\|ssh_keys' …` exits 1 on a file that
contains nine matches. Any lane that ran the alternation form and reported "not_found" reported
a **tooling artifact, not an absence**. Use repeated `-e` flags (or `-E`).

    git grep -c 'resolveSSHKey\|BARKPARK_SSH_KEY' origin/main -- internal/cli/cloud/provider.go   → exit 1, no output
    git grep -c -e 'resolveSSHKey' -e 'BARKPARK_SSH_KEY' origin/main -- internal/cli/cloud/provider.go
      → origin/main:internal/cli/cloud/provider.go:9
