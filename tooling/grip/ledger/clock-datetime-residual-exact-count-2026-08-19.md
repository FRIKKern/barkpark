<!-- doc-tier: cold | canonical-for: none | budget: 4000tok -->
# Re-derivation: exact DateTime.utc_now survivor count (clock-semantics wave)

Verifier assignment `datetime-residual-count`. All reads from `origin/main`.

## 1. Denominator (366, not 256+110=366 — reconciles)

    git grep -n 'DateTime.utc_now' origin/main -- api/lib cloud/lib > /tmp/dtn.txt && wc -l /tmp/dtn.txt
    # 366

## 2. The surveyor's mechanical drop filter, and its residual

    grep -cE '(inserted_at|updated_at|_at:|assign\(.*:now)' /tmp/dtn.txt   # 98 dropped
    grep -vE '(inserted_at|updated_at|_at:|assign\(.*:now)' /tmp/dtn.txt   # 268 residual
    grep -cE 'DateTime\.utc_now/0|:[0-9]+: *#' /tmp/dtn.txt                # prose subset

Residual splits 11 prose/doc-arity references + 257 real call sites.

## 3. Column-reachability test (the decisive step)

A stamp is a survivor only if some read path compares that column temporally:

    for c in revoked_at suspended_at confirmed_at verified_at claimed_at last_active_at \
             last_seen_at occurred_at checked_at processed_at resolved_at exported_at \
             projected_at saved_at measured_at update_checked_at became_live_at first_seen_at; do
      echo "$c $(git grep -nE "$c\s*(<|>|<=|>=)|DateTime\.(diff|compare)\([^)]*$c" origin/main -- api/lib cloud/lib | wc -l)"
    done
    # all zero except revoked_at/suspended_at (is_nil-gated, never temporal)

Positive controls (columns that ARE compared, so their writes are survivors under
the inclusive rule):

    git grep -n 'agent_state_at' origin/main -- api/lib          # :736 `< ^cutoff`
    git grep -n 'vercel_claim_minted_at' origin/main -- cloud/lib # :169 write, :119 @claim_ttl_ms

## 4. Downstream-use dump per bare `now =` site

Script pattern: for each residual site, walk backwards to the enclosing `def`,
then forward to the next `def`, printing every line mentioning `now`. That
separates "now feeds a WHERE/compare" from "now is only stamped".

## 5. Verdicts

- Decision-sites-only rule (clock read is itself compared): 83 survivors
  (48 api + 35 cloud).
- Inclusive rule (also counts the paired write of the stored instant a bound
  later compares): 120 survivors (72 api incl. 1 class-D + 48 cloud).
- Surveyor reported 64. The gap is RULE DEFINITION, not sampling error.

## 6. Corrections to the assignment brief

- `api/lib/barkpark/audit/export.ex:127` and `api/lib/barkpark/media/delivery/events.ex:147`
  are `System.system_time(:second)` sites, NOT DateTime.utc_now — already inside
  the exactly-read 49-hit family. The DateTime hits in those files are
  `export.ex:175 auto_disabled_at` and `events.ex:93 timestamp:` (both drops).
- New class-D candidate found: `api/lib/barkpark/webhooks.ex:574`
  `fence = DateTime.utc_now()` written into `updated_at` and used as an
  equality CAS token (`d.updated_at == ^delivery.updated_at`). Required
  property is "never repeats", so neither pure source is right — class D.
