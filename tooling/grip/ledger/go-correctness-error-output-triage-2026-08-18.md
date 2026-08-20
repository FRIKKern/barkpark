<!-- ledger: re-derivation recipes for go-correctness wave, v-error-output-triage lane -->

# Error-output triage — re-derivation recipes (origin/main 77ed4335)

## Claim 1: output.go:263/:274 `_ = enc.Encode(v)` does NOT silently exit-0-truncate on a broken pipe

The candidate worried `bp ... -o json | head` swallows a stdout write error and exits 0.
REFUTED for the EPIPE case: Go's runtime raises SIGPIPE on a broken-pipe write to fd 1,
terminating the process with exit 141 (128+13) BEFORE the swallowed error matters.

Re-derive:

    git show origin/main:internal/cli/output.go | sed -n '258,276p'   # see the two `_ = enc.Encode`
    # minimal repro of the exact pattern (encode big payload to os.Stdout, swallow err, os.Exit(0)):
    #   json.NewEncoder(os.Stdout).Encode(map{5MB string}); os.Exit(0)
    #   run:  ./ep | head -c 1 >/dev/null ; echo ${pipestatus[1]}   -> 141, not 0

Residual (idiomatic, DROP): a redirect to a FULL DISK (fd 1 = regular file) returns ENOSPC,
not EPIPE, so no SIGPIPE — Encode's error IS swallowed and exit stays 0 with truncated JSON.
This is idiomatic Go (cobra/kubectl swallow stdout write errs too); surfacing it needs an error
threaded up through every renderJSON call site (high blast radius, near-zero value). The other two
enc.Encode sites (make_cmd.go:238, onramp_write.go:568) already do `if err := enc.Encode(...)`.

## Claim 2: chathost SaveState "ZERO production callers" — the absence-claim is FALSE, but SaveState is SAFE anyway

Re-derive:

    git grep -n 'SaveState' -- '*.go' | grep -v _test
    # -> internal/chathost/state.go:18 (def) AND cmd/barkpark-chat-host/main.go:41 (CALLER)

The digest said zero callers; there is exactly one, in cmd/ (outside internal/ fence).
Dropped-error worry is moot NOT because unused but because:
  - SaveState returns errors on every fallible op (MkdirAll/Marshal/WriteFile/Chmod/Rename), atomic temp+rename;
  - its one caller checks it: `if err := chathost.SaveState(...); err != nil { fatal(...) }`.
Verdict: SAFE — no dropped error. DROP.
