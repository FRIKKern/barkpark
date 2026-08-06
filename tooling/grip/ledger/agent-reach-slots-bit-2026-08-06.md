# agent-reach-slots-bit — 2026-08-06 (verifier, wave 5)

Re-derivation recipes for the "is the fence dark on 5 of 6 boxes, and why" bit.
Every row is a command; run it, don't trust this file.

## 1. Host roster (slug -> IP)

```
bp cloud status -o json | python3 -c 'import sys,json;[print(b["slug"],b["host"]) for b in json.load(sys.stdin)["barkparks"]]'
```
2026-08-06: gyldendal 5.75.169.183 · muscle-1 46.224.19.120 (agent offline) ·
dooodo 116.203.91.216 · guerrilla 157.180.90.121 · gyl 46.225.61.223 · jarl 91.98.139.58

## 2. The slots bit + the stale-binary detector (per box)

```
ssh -i ~/.ssh/barkpark_indx root@<ip> 'hostname; ls -d /opt/barkpark/.slots; \
  ls -l /usr/local/bin/barkpark-agent /etc/barkpark/agent.token; \
  strings -a /usr/local/bin/barkpark-agent | grep -c cpu_cores'
```

NOTE: gyl (46.225.61.223) and dooodo (116.203.91.216) FAIL host-key verification
against ~/.ssh/known_hosts:53 / :54 (rebuilt boxes / reassigned IPs). Add
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` to probe WITHOUT
mutating known_hosts. Do not blind-accept into known_hosts.

2026-08-06 result:
| box | .slots | agent mtime | agent.token mtime | grep -c cpu_cores |
|---|---|---|---|---|
| guerrilla | PRESENT | Aug 6 14:22 | — | 1 |
| jarl | ABSENT | Jul 30 14:25 | Jul 30 14:25 | 0 |
| gyl | ABSENT | Aug 5 12:05 | Aug 5 12:05 | 0 |
| dooodo | ABSENT | Jul 24 12:06 | Jul 24 12:06 | 0 |
| gyldendal | ABSENT | Jul 9 16:38 | Jul 9 16:38 | 0 |

agent mtime == agent.token mtime TO THE MINUTE on all four => the binary was built
ONCE at warm-pool arm time and never since.

## 3. The detector generalises (use as the unmetered marker)

```
for k in cpu_cores pss_bytes swap_bytes top_relations load1; do \
  printf "%s=%s\n" "$k" "$(strings -a /usr/local/bin/barkpark-agent | grep -c $k)"; done
```
guerrilla: cpu_cores=1 pss_bytes=1 swap_bytes=1 top_relations=1 load1=1
jarl/gyl:  cpu_cores=0 pss_bytes=0 swap_bytes=0 top_relations=0 load1=1

## 4. The wire agrees (no ssh needed — this is the cheap check)

```
CT=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])")
TEAM=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_team'])")
curl -s -H "Authorization: Bearer $CT" -H "X-Barkpark-Team: $TEAM" https://barkpark.cloud/v1/barkparks \
 | python3 -c 'import sys,json;[print(b["slug"],"->",json.dumps(b.get("pressure"))) for b in json.load(sys.stdin)["barkparks"]]'
```
NB: the CONTENT token (config.json .token) 401s here; the CLOUD token + team header is required.

## 5. Why the routine self-update never fixes it

```
for f in scripts/apply-update.sh scripts/deploy-rebuild.sh scripts/self-update.sh; do \
  echo "$f=$(git show origin/main:$f | grep -c agent)"; done      # all 0
git show origin/main:deploy/instance-deploy.sh | sed -n '806,826p' # the ONLY rebuild block
git show origin/main:deploy/instance-deploy.sh | sed -n '147p'     # PATH incl /usr/local/go/bin
git show origin/main:deploy/instance-deploy.sh | sed -n '669p'     # mkdir -p $APP/.slots (unconditional)
git grep -n 'go build -o .*barkpark-agent' origin/main -- internal/cli/cloud/warmpool.go  # :618, the once-only build
```

## 6. Release blessing is a NON-fix

```
git log -1 --format='%h %cd' v0.2.25          # 15fbded39 Wed Jul 8 2026 — a month stale
git show -s --format='%h %cd %s' fc6a74ca2    # #9824, cpu_cores, Thu Aug 6 2026
```
No self-update script builds the agent at all, so no tag can carry it.

## 7. `command -v go` is a false negative over ssh

```
ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 'command -v go || echo NO_GO; ls -d /usr/local/go/bin/go'
```
=> NO_GO, /usr/local/go/bin/go. Go IS installed; only the non-login PATH misses it.
instance-deploy.sh:147 exports it, so its `command -v go` guard passes when the
script actually runs. Do not conclude "no toolchain" from a bare ssh probe.
