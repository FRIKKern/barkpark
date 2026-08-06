# cch-w37 verify — friendly() reach and the two error keys (2026-08-06)

Baseline: `origin/main` = `bf97452bb38488d04cfbb596c2528a3f34ad5baf`.
app.js 20,959 lines; router.ex 12,678 lines.

## Re-derivation recipes

Key counts (LINES; the two literals are disjoint — `detail:` does not match `details:`):

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c 'detail:'    # 58
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c 'details:'   # 51
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c 'error: "invalid"'            # 60
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c 'error: "invalid", details:'  # 47
    git grep -c 'details:' origin/main -- 'cloud/lib/**/*.ex'   # router.ex only, 51

POST /v1/sites renders the raw slug (no `friendly()`):

    git show origin/main:cloud/priv/static/app.js | grep -n 'api("POST", "/v1/sites", body)' -A 20
    # :8410  var msg = (r.data && (r.data.error || r.data.message)) || ("create failed (" + r.status + ")");
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '6181p'
    # {:error, %Ecto.Changeset{} = cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})

friendly()'s read set (never `.detail`):

    git show origin/main:cloud/priv/static/app.js | sed -n '280,297p'

Go control-plane client decodes `error` + `detail`, never `details`:

    T=$(mktemp -d); git archive origin/main internal go.mod go.sum | tar -x -C $T
    sed -n '258,296p' $T/internal/cloudclient/client.go
    cd $T && CC=/usr/bin/clang go build ./... && go vet ./internal/cli/... && go test ./internal/cloudclient/...

Mutation probe (temp tree only, never committed) proving the blindness:

    cat > $T/internal/cloudclient/zz_probe_test.go <<'EOF'
    package cloudclient
    import "testing"
    func TestProbeDetailsBlindness(t *testing.T) {
      t.Logf("%q", cloudError(422, []byte(`{"error":"invalid","details":{"name":["can't be blank"]}}`)).Error())
      t.Logf("%q", cloudError(422, []byte(`{"error":"invalid","detail":"bind it with --dataset"}`)).Error())
    }
    EOF
    cd $T && CC=/usr/bin/clang go test ./internal/cloudclient/ -run TestProbeDetailsBlindness -v
    # => "invalid"
    # => "invalid: bind it with --dataset"

Second CLI decoder (generic classifier) is blind the same way — flat cloud envelope
lands in the bare-string arm, `case "invalid"` returns message == "invalid":

    sed -n '188,214p' $T/internal/cli/errors.go

Route/helper attribution of the 48 HTTP-emitting `details:` lines: forward scan
binding each line to the nearest preceding `get|post|put|patch|delete "…"` macro or
`defp`. 30 sit in a route macro; 18 sit in a private helper and are reported
UNATTRIBUTED-to-route by name (2196, 2200, 8249, 8447, 8882, 8896, 8909, 8920,
9198, 9202, 9205, 11088, 11194, 11830, 12128, 12333, 12396, 12624).

friendly()-reachability of the 30 route-scope emitters was decided by locating each
route's `api(` call site in app.js and reading its error branch (directly or through
its copy wrapper — `addSupportErrorCopy`, `envVarWriteFailureCopy`, `inviteFailureCopy`,
`faultCopy`, all of which terminate in `friendly()`).
