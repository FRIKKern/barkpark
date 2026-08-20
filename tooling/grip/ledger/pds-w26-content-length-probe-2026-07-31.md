# PDS w26 — content-length-probe re-derivation recipes

Question: does a declared size exist to compare bytes-written against, for M4's
sinks? Answer: **yes for the workspace-export HTTP sink, no for the S3 sink, and
the question is malformed for `bp export --out`.**

## R1 — live export route carries a real Content-Length (curl, no Accept-Encoding)

    curl -s --max-time 280 -D- -o /tmp/exp1.tar \
      -H "Authorization: Bearer $(jq -r .token ~/.config/barkpark/config.json)" \
      -H "Accept: application/x-tar, application/json" \
      "https://guerrilla.barkpark.cloud/api/workspaces/default/export?profile=dev" \
      && ls -l /tmp/exp1.tar

Expect `content-type: application/x-tar`, **no** `content-encoding`, and
`content-length: <N>` equal to the on-disk byte count.

## R2 — Go sees it too; transparent gzip does NOT fire on x-tar

Probe source: `tooling/grip/ledger/pds-w26-content-length-probe-main.go.txt`
(GET that rebuilds `newTransferClient()` verbatim from `internal/cli/run.go:969`
and prints `resp.ContentLength`, `resp.Uncompressed`, then the `io.Copy` count).
Copy it to a scratch dir as `main.go`, `go mod init clprobe`, then:

    T=<bp token> go run . "https://guerrilla.barkpark.cloud/api/workspaces/default/export?profile=dev"

Expect `Uncompressed=false`, `ContentLength=<N>`, `copied=<N>`, `match=true`.

## R3 — the -1 hazard is REAL, just not on this route

Same probe, JSON route:

    T=<bp token> go run . "https://guerrilla.barkpark.cloud/api/schemas"

Expect `ContentLength=-1 Uncompressed=true` — Go added `Accept-Encoding: gzip`
itself, the server gzipped (JSON is compressible), Go decompressed transparently
and **stripped Content-Length**. A naive `if n != resp.ContentLength { fail }`
fails every SUCCESSFUL call here. Guard `-1` → `verified:false`, never a failure.

## R4 — the S3 sink has no size, but the SDK does

    git show origin/main:internal/hetzner/objstore/client.go | grep -n 'func (c \*Client)'
    git grep -n 'HeadObject' origin/main -- internal/       # → empty
    grep -n 'ContentLength' \
      "$(go env GOMODCACHE)"/github.com/aws/aws-sdk-go-v2/service/s3@v1.104.2/api_op_GetObject.go

`Client.GetObject` returns `(io.ReadCloser, error)` and throws away
`GetObjectOutput.ContentLength *int64` (line 532). No `Head*` method exists. The
declared size is one struct field away — the fix is a signature change, not a
new round-trip.

## R5 — the bundle is not byte-stable across runs

Three consecutive exports of the same scope returned 134877184 / 134879744 /
134884864 bytes. Content-Length is truth **within one response only**; never
compare across runs or against a cached expectation.
