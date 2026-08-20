# V5 — cloud_support sources + provisioner "twins" re-derivation (2026-08-18)

Class: command-injection / missing-guard. Verdict: CLEAN-A (proven-zero, taint-based).

## Claim 1 — worker/agent/pkg/bin in cloud_support_cmd.go are all trusted, gated before interpolation
```
grep -n 'supportAgentPackages\|supportNameRe\|r.agent =\|_, ok := supportAgentPackages' internal/cli/cloud_support_cmd.go
grep -n 'supportURLSafeRe\|supportTokenSafeRe\|supportSlugRe\|supportNameRe\|supportClassVocab' internal/cli/cloud_support_cmd.go
```
- pkg/bin: values of the compile-time constant map `supportAgentPackages` (155), keyed by `r.agent` allowlisted to claude|codex at 232. Not remote.
- worker=r.name: `supportNameRe` DNS-label gate at 223 (create) / 951 (remove), before runtime steps at 792/805.
- agent: allowlisted; single-quoted at builder 1673. base URL gate 245, slug gates 269/272, token gate 598, maxClass gate `supportClassVocab[maxClass]` 1662. All gate BEFORE `supportUnitInstallStep`/`supportAgentInstallStep`.

## Claim 2 — provisioner/warmpool.go + restore_driver.go are NOT forked shell twins; they build zero shell
```
git show origin/main:internal/provisioner/warmpool.go   | grep -cE 'exec\.Command|bash|-lc|Argv'   # -> 0
git show origin/main:internal/provisioner/restore_driver.go | grep -cE 'exec\.Command|bash|-lc|Argv' # -> 0
git show origin/main:internal/cli/cloud/warmpool.go      | grep -cE 'bash|-lc|Argv'                   # -> many
git show origin/main:internal/cli/cloud/restore_driver.go| grep -nE 'bash|-lc|Argv'                   # 333,338,344,397
```
Provisioner files are HTTP-client + orchestration layers; all shell construction lives once in cli/cloud/*, guards intact (secretKeyShape/secretValueAlphabet fail-closed at restore_driver.go ~371-374; AzureBaseInstallScript constant). No dropped-guard fork.

## Build/vet
```
CC=/usr/bin/clang go build ./...            # exit 0
CC=/usr/bin/clang go vet ./internal/cli/ ./internal/provisioner/  # exit 0
```
(cc alias shadows the compiler — CC=/usr/bin/clang required, else `error: unknown option '-E'`.)
