# cch-w71 — dns-label rider: platform_host fourth-copy + write-path scope (re-derivation)

Verifier: dns-label-fourth-copy lane. All bytes read from `origin/main` (not worktree).

## Does platform_host still diverge? (fourth normaliser copy) — YES

    git show origin/main:cloud/lib/barkpark_cloud/domain_status.ex | sed -n '227,241p'
    git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | sed -n '438,446p'

`DomainStatus.platform_host/1` (domain_status.ex:227) — NOTE the real path is
`cloud/lib/barkpark_cloud/domain_status.ex`, NOT `.../registry/domain_status.ex`
(that path does not exist on origin/main). It does: `String.trim` → strip
`https://`/`http://` → `String.split("/", parts: 2) |> hd` (drop path) →
`String.split(":", parts: 2) |> hd` (drop port). Returns the FULL host WITH the
`.<base_domain>` suffix (a status-check target), falls back to
`Barkpark.provisioning_fqdn/1`.

`Barkpark.subdomain_from_url/1` (registry/barkpark.ex:439) does: strip
`https://`/`http://` → strip `.<base_domain>` suffix. Returns the LABEL (suffix
stripped), the DNS record + Hetzner box name. NO trim, NO port/path strip, NO
case fold, keeps trailing dot.

The divergence is already TABULATED on origin/main in the test moduledoc
(`cloud/test/barkpark_cloud/registry_claim_host_normaliser_test.exs:238-247`):

    copy                          | trims? | folds case? | strips port/path? | trailing dot?
    normalize_claim_host/1 (twin) | yes    | yes         | yes               | stripped
    the SQL fragment (twin)       | yes    | yes         | yes               | stripped
    subdomain_from_url/1          | NO     | NO          | NO                | kept
    platform_host/1               | yes    | NO          | yes               | kept

## Should the rider converge BOTH read-side copies? — NO, scope to subdomain_from_url only

- The two copies produce DIFFERENT outputs (label-without-suffix vs
  full-host-with-suffix) and serve different stakes: subdomain_from_url mints a
  DNS record + a Hetzner box name (provisioning write); platform_host only
  decides which hostname a status panel probes (read/display). They cannot share
  one function; at most a shared normalize-prelude.
- platform_host already trims + strips port/path; its only residual gaps are
  case-fold + trailing-dot — low-stakes on a display path.
- The test moduledoc EXPLICITLY warns against folding platform_host into a
  claim/label fix ("quietly rewriting a DNS-label derivation under that heading
  would ship a provisioning change inside a tenancy fix"). Filing the rider as a
  two-copy convergence over-scopes it and risks the same anti-pattern.
- Recommendation: rider closes subdomain_from_url ONLY (bring it to the twins'
  full normalization: trim + case-fold + strip port/path + strip trailing dot).
  Optionally extract a shared host-normalizer both can call, but that is a
  nice-to-have, not the rider's contract.

## Every write path to barkparks.url — ALL funnel through Barkpark.changeset/2; NONE bypass

    git grep -nE '%Barkpark\{|Barkpark\.changeset|\|> Barkpark' origin/main -- cloud/lib
    git grep -nE 'update_all|insert_all|Repo.query|fragment' origin/main -- cloud/lib/barkpark_cloud | grep -i url

1. `Registry.insert_with_url_reservation/4` (registry.ex:372) — `Map.put(attrs,
   :url, candidate)` where candidate = `Barkpark.clean_url(slug)` or
   `Barkpark.provisioning_url({slug,tid})` (both machine-built by string concat,
   clean by construction; Map.put OVERWRITES any caller-supplied url) → insert_fun
   → `register_barkpark/2`/`register_support_barkpark/2` → `insert_barkpark/2`
   (registry.ex:240) → `Barkpark.changeset/2` → Repo.insert.
2. `Registry.upsert_barkpark/2` existing-row (registry.ex:262) →
   `Barkpark.changeset(attrs)` → Repo.update (takes caller attrs directly, NOT
   via reservation).
3. `Registry.adopt_barkpark/3` (registry.ex) → register_barkpark → changeset.

NO Repo.update_all / insert_all / raw SQL / fragment writes barkparks.url (the
update_all hits are all accounts.ex token revocation; barkpark.ex:604-606's
update_all note is suspend/resume flags only).

CRUCIAL: `Barkpark.changeset/2` (registry/barkpark.ex:497) CASTS `:url` but
applies NO validate_format, NO trim, NO normalization to it (read lines
499-540). So the single write chokepoint exists but is a no-op for url hygiene
today — which is exactly what #11850 (worker-route stores url unnormalised) adds,
and why subdomain_from_url must be independently robust (defense-in-depth).

## Red-proof MUST feed subdomain_from_url a struct-level dirty url — CONFIRMED

Because ALL writes funnel through changeset/2, #11850 may sanitize url mid-wave.
subdomain_from_url is a PURE struct function, so the red fixture must construct
`%Barkpark{url: <dirty>}` at struct level (bypassing the write/changeset path) —
a write-path fixture would go green for the wrong reason once #11850 lands.

The canonical example ALREADY EXISTS on origin/main
(`registry_claim_host_normaliser_test.exs:685`, `describe "the third and fourth
copies"`):

    raw = " https://Gyldendal.barkpark.cloud."
    bp = %Barkpark{url: raw}
    label = Barkpark.subdomain_from_url(bp)
    refute label == "gyldendal", "...close cch-w69-bl-dns-label-minted-from-raw-url..."

This is a live TRIPWIRE the builder FLIPS: change `refute` → `assert label ==
"gyldendal"` and update the divergence table's subdomain_from_url row to
yes/yes/yes/stripped. No new fixture need be authored; the acceptance-floor red
is the pre-flip `assert` failing on today's non-normalizing bytes.
