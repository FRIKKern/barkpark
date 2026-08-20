# cch-w68-s5 — the re-check's fail-before run and its mutation transcript (D834)

The durable record acceptance criterion 1 asks for. Taken 2026-08-17 against
`origin/main = a6535504204df39850cb1d08316b5ffb25eb983b` (S2 / #11707 merged),
in a worktree on branch `loop-epic/cch-w68-s5-recheck-settle`.

Everything below is re-runnable from the repo root. The mutation driver is not
committed under `cloud/priv/static` (the harness fence) — it is reproduced in
§3 in full so the run can be rebuilt from this file alone.

## 1 — THE DEFECT, MEASURED ON THE SHIPPED BYTES

`recheckSiteDeleted`'s pre-fix predicate was, verbatim:

    var gone = r.status === 404 || (r.ok && !(r.data && r.data.site));

and every `true` toasted `"<name> is no longer registered — the teardown
completed after all."` Driven through the shipped `api()` (never hand-built
envelopes — the fix rests on `api()`'s own `text` field, so a hand-written
fixture would pin the author's belief about the envelope instead of the
envelope), SEVEN answers were classified. Five took the success arm:

| # | answer | `r.text` | old `gone` | new verdict |
|---|---|---|---|---|
| 1 | route 404, `application/json`, `{"error":"not_found"}` | `null` | true | `gone` |
| 2 | 200 `text/html` sign-in interstitial | bytes | true | `unknown` |
| 3 | 200 `application/json` `{}` | `null` | true | `unknown` |
| 4 | proxy 404, `text/html` (nginx — the route never ran) | bytes | true | `unknown` |
| 5 | 204 No Content (no content-type at all) | `""` | true | `unknown` |
| 6 | 200 with the site envelope (honest control) | `null` | false | `registered` |
| 7 | 500 `{"error":"server_error"}` (honest control) | `null` | false | `failed` |

The discriminator is `r.text`, and it is exact rather than heuristic. `api()`
sets `text: null` for every `application/json` body (parsed OR unparseable) and
carries the bytes for every other body. The control plane answers
`GET /v1/sites/:id` only through `router.ex`'s `json/2`
(`put_resp_content_type("application/json")`), and its miss is
`json(conn, 404, %{error: "not_found"})` — so on this path `text == null` means
the plane itself spoke, and a non-null `text` means something in front of it
answered instead:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'nil -> json(conn, 404'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n -A3 'defp json(conn, status, body)'

## 2 — FAIL-BEFORE: the new and flipped assertions against origin/main's app.js

The new test file held constant; `app.js` and `__unknown_census.mjs` swapped for
their `origin/main` bytes:

    git show origin/main:cloud/priv/static/app.js > cloud/priv/static/app.js
    git show origin/main:cloud/priv/static/__unknown_census.mjs > cloud/priv/static/__unknown_census.mjs
    node --test cloud/priv/static/__app.test.mjs

Output (`grep -E "^not ok|^# (tests|pass|fail)"`):

    not ok 956  - cch-w34-s1/cch-w67-s4: the per-GET-call-site census runs clean against the shipped app.js
    not ok 1070 - cch-w67 + cch-w68-s5: the settle plan survives a modal dismissed mid-flight — a late FAILURE still speaks, and a late SUCCESS on this site's screen NOW navigates (D834)
    not ok 1076 - cch-w68-s5 (D834): the FIVE answers that used to read as a completed teardown are classified apart — and only the plane's own 404 is 'gone'
    not ok 1077 - cch-w68-s5 (D834): DRIVEN — a 200 text/html, a 200 JSON {}, a proxy 404 and a 204 each render the unknown sentence and NEVER the success toast
    not ok 1078 - cch-w68-s5 (D834): the plane's OWN 404 still settles the dialog — with the causal teardown claim removed
    not ok 1079 - cch-w68-s5 (D834): the four re-check sentences are DISTINCT, and the unknown arm prescribes nothing
    not ok 1080 - cch-w68-s5 (D834e): the Re-check is BOUNDED — three reads, then the dialog stops offering it
    not ok 1081 - cch-w68-s5 (D834): a successful delete invalidates the sites list BY THE MUTATION — no hash change required
    # tests 1081
    # pass 1073
    # fail 8

After the slice: `# tests 1081 / # pass 1081 / # fail 0`. Baseline on
`origin/main` was 1075/1075 (D832's figure), so the slice adds SIX tests and
flips TWO pins.

Two of the eight are DELIBERATE FLIPS of shipped assertions, both cited in the
diff: the `lateOk` pin asserting `navigate:false` (D834's re-ruling) and the
census row pinning `recheckSiteDeleted` as `degrades` (which D832 explicitly
left to this slice). The other six are new.

## 3 — MUTATION: seven reverts, seven kills

A whole-file fail-before proves the assertions are new; it does NOT prove they
pin the DISCRIMINATOR rather than the mere presence of the new exports (against
`origin/main` they die on `hooks.siteRecheckVerdict` being `undefined`). So each
guard was mutated back to the pre-fix byte, or stripped of exactly one clause,
with the rest of the slice in place. Driver (run from the scratchpad, patching
`app.js` in place and restoring it):

    // each MUTANT is {from, to}; the driver refuses (exit 2) if `from` is
    // absent (the mutation would be a no-op) or if the baseline is not green,
    // runs `node --test`, records every `^not ok`, and restores the file.
    M1  if (r.status === 404) return planeSpoke ? "gone" : "unknown";
     ->  if (r.status === 404) return "gone";
    M2  if (r.ok) return r.data && r.data.site ? "registered" : "unknown";
     ->  if (r.ok) return r.data && r.data.site ? "registered" : "gone";
    M3  the 404 arm's body -> "… is no longer registered — the teardown completed after all."
    M4  navigate: !!onSite  ->  navigate: !!live && !!onSite
    M5  retryable: !settled && n < SITE_RECHECK_MAX_ATTEMPTS  ->  retryable: !settled
    M6  delete the invalidateDeletedSite(site.id) call from runSiteDelete
    M7  var evidence = detail ? " The server replied: " + detail : "";  ->  var evidence = "";

Transcript:

    BASELINE (unmutated): fail=0

    M1 — REVERT the 404 discriminator: a proxy 404 is 'gone' again (pre-fix half)
      fail=3
      RED: cch-w34-s1/cch-w67-s4: the per-GET-call-site census runs clean against the shipped app.js
      RED: cch-w68-s5 (D834): the FIVE answers that used to read as a completed teardown are classified apart — and only the plane's own 404 is 'gone'
      RED: cch-w68-s5 (D834): DRIVEN — a 200 text/html, a 200 JSON {}, a proxy 404 and a 204 each render the unknown sentence and NEVER the success toast

    M2 — REVERT the 2xx discriminator: every site-less 2xx is 'gone' again (pre-fix other half)
      fail=3
      RED: cch-w68-s5 (D834): the FIVE answers that used to read as a completed teardown are classified apart — and only the plane's own 404 is 'gone'
      RED: cch-w68-s5 (D834): DRIVEN — a 200 text/html, a 200 JSON {}, a proxy 404 and a 204 each render the unknown sentence and NEVER the success toast
      RED: cch-w68-s5 (D834e): the Re-check is BOUNDED — three reads, then the dialog stops offering it

    M3 — RESTORE the causal clause on the 404 arm
      fail=1
      RED: cch-w68-s5 (D834): the plane's OWN 404 still settles the dialog — with the causal teardown claim removed

    M4 — REVERT the settle predicate to !!live && !!onSite (D834's flipped pin)
      fail=1
      RED: cch-w67 + cch-w68-s5: the settle plan survives a modal dismissed mid-flight — a late FAILURE still speaks, and a late SUCCESS on this site's screen NOW navigates (D834)

    M5 — REMOVE the Re-check bound: retryable forever
      fail=1
      RED: cch-w68-s5 (D834e): the Re-check is BOUNDED — three reads, then the dialog stops offering it

    M6 — REMOVE the mutation-owned list invalidation from runSiteDelete
      fail=1
      RED: cch-w68-s5 (D834): a successful delete invalidates the sites list BY THE MUTATION — no hash change required

    M7 — STRIP the evidence clause from the unknown arm (the only thing D332 allows it to add)
      fail=1
      RED: cch-w68-s5 (D834): DRIVEN — a 200 text/html, a 200 JSON {}, a proxy 404 and a 204 each render the unknown sentence and NEVER the success toast

    restored byte-identical: true

    ALL MUTANTS KILLED.

Note M1 and M2 each red the census as well as the harness: the census row's
`fileProof` pins the discriminator LINE, so reverting the classifier is a
verdict decay the gate sees independently.

M7 is the one worth stating plainly: without it, an `unknown` arm that quietly
stopped showing the proxy's recovered bytes would ship green. D332(d) says the
honest copy IS the evidence string and the fix is the ABSENCE of advice — so the
evidence clause is the load-bearing half of that arm, and it now has a guard.

## 4 — SCOPE FENCE, PROVED BY BYTES NOT BY ASSERTION

D834 fences this slice to `recheckSiteDeleted`. `siteLoadFailureHtml` carries
the identical OLD predicate one screen away and its "200-with-no-site is an
absence" pin is a shipped cch-w66-s3 decision. Extracted by brace-walk from
both revisions and compared:

    siteLoadFailureHtml     BYTE-IDENTICAL (1175 bytes)
    deployLoadFailureHtml   BYTE-IDENTICAL (548 bytes)
    faultDetail             BYTE-IDENTICAL (367 bytes)
    cch-w66-s3 pins         BYTE-IDENTICAL (5390 bytes, 3 tests)

## 5 — GATE

    node --check cloud/priv/static/app.js                    # exit 0
    node cloud/priv/static/__unknown_census.mjs
    #   OK: all 61 GET call sites equal the pin (48 guarded · 12 sanctioned · 1 degrades)
    #   and every verdict proof holds.
    node --test cloud/priv/static/__app.test.mjs             # 1081/1081

The census moves 47/12/2 -> 48/12/1. The one remaining `degrades` row is
`openCommandPalette`, owned by
`cch-w34-bl-five-remaining-absence-collapses`. The set is the gate, never the
size.
