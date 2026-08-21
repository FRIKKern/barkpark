# Independent security derivation — dr-w2-s7 public-read visibility clamp

- **Reviewer agent:** `scoped-search-leak` (did NOT build the slice; no authorship
  in PR #9734 and no prior context on it beyond the two task rows).
- **Date:** 2026-08-21
- **origin/main SHA read:** `519b9dade9897c966d8ebf79283184069b90007b`
- **Payer commit under review:** `f36fe8ea90ed5a94e007dbd05d2924bbfdbea4f9`
  ("fix(search): clamp the public-read tier on the scoped search door, keyed on
  permission (#9734)")
- **Verdict: the derivation CONFIRMS the fix. It does NOT reverse it.**

## Ancestry

    $ git merge-base --is-ancestor f36fe8ea90ed5a94e007dbd05d2924bbfdbea4f9 origin/main
    $ echo $?
    0

    $ git show --stat --oneline f36fe8ea90ed5a94e007dbd05d2924bbfdbea4f9
    api/lib/barkpark/search/documents_retriever.ex     |  65 +++-
    api/lib/barkpark_web/controllers/query_controller.ex   |  27 +-
    .../search/documents_retriever_visibility_test.exs |  71 ++++-
    .../barkpark_web/channels/search_channel_test.exs  |  34 +-
    .../public_read_private_type_clamp_test.exs        | 353 +++++++++++++++++++++

Both halves the retriever's own comment names as a parity pair moved in ONE
commit. Shipping the retriever alone would have been a false claim; it was not
shipped alone.

## What the bytes say on origin/main

`api/lib/barkpark/search/documents_retriever.ex:344-371`:

    defp restrict_anonymous_to_public_types(query, scope, opts) do
      if bypasses_visibility_gate?(Keyword.get(opts, :caller_context)) do
        query
      else
        where(query, [d], d.type in ^public_type_names(scope, opts))
      end
    end

    defp bypasses_visibility_gate?(%{principal_type: p} = ctx) when p in [:api_token, :user],
      do: not public_read_principal?(ctx)

    defp bypasses_visibility_gate?(_), do: false

    defp public_read_principal?(%{roles: roles}) when is_list(roles), do: "public-read" in roles
    defp public_read_principal?(_), do: false

The parity partner, `api/lib/barkpark_web/controllers/query_controller.ex:738-741`:

    defp authed?(conn) do
      not is_nil(conn.assigns[:api_token]) and
        not BarkparkWeb.Plugs.PublicRead.public_read_token?(conn)
    end

Three properties checked by reading, each of which would have been a defect:

1. **MEMBERSHIP, not list equality.** `"public-read" in roles` — a real
   `["public-read", "read"]` mint cannot walk past it. A `roles == ["public-read"]`
   pin would have been escapable by construction, since `TokenController`
   returns the permission list verbatim and unordered.
2. **The roles feed is real on the leaking door.** `CallerContext.from_token/1`
   (`api/lib/barkpark/content/caller_context.ex:50-54`) copies the token's
   `permissions` into `:roles` verbatim, and `ScopeHelpers.from_assigns/2`
   (`api/lib/barkpark_web/plugs/scope_helpers.ex:70-76`) puts a `:caller_context`
   into the opts of EVERY scoped read. This was the fail-open surface worth
   checking: `public_read_principal?(_) -> false` means an absent or non-list
   `:roles` yields *bypass*, so a scoped pipeline that failed to populate roles
   would have left the leak wide open with the clamp visibly "present". It does
   populate them.
3. **The clamp filters, it never denies.** `Plugs.PublicRead` is NOT mounted on
   `:scoped_api`, correctly: 21 routes ride that pipeline bare and PublicRead is
   deny-by-default outside a GET query/doc/graph allowlist, so mounting it would
   have 403'd the live flagship (search-template D49). Every clamped case below
   returns 200 with an empty result.

## Cases DRIVEN that the builder never drove

New file `api/test/barkpark_web/integration/public_read_clamp_independent_derivation_test.exs`
— not a copy of the builder's canary. It seeds `mediaAsset` (a type the LIVE
census names private, and one the media surface also resolves) rather than the
builder's synthetic `ledger`; it drives `{read}` and `{admin}` as first-class
cases; and it pins the COUNT at zero, because a surviving count is an existence
leak by itself.

    $ cd api && CC=clang MIX_ENV=test mix test \
        test/barkpark_web/integration/public_read_clamp_independent_derivation_test.exs
    7 tests, 0 failures

Doors driven: scoped `/v1/data/search` (mixed `[public-read, read]` token,
singleton `[public-read]` token, `?types=` narrowing onto the private type),
scoped `/v1/search` federated documents surface, plus `{read}` and `{admin}`
non-regression on both.

## MUTATION PROOF — the green is not vacuous

The clamp was broken on origin/main bytes by reverting `bypasses_visibility_gate?/1`
to its pre-fix principal_type-only shape (`do: true`), then restored.

**Existing suite under mutation — 7 named reds:**

    34 tests, 7 failures
    1) a MIXED [public-read, read] token is clamped too — membership, never list equality
       left: "leak-session"  right: ["leak-session", "pub-post"]
    2) a bare public-read token is clamped to the public allowlist, like an anonymous caller
    3) scoped federated search — CANARY: a mixed public-read token is clamped on the federated door too
       left: "prpt-private"  right: ["prpt-private", "prpt-public"]
    4) scoped search — CANARY: a mixed public-read token gets the public row and NOT the private one
    5) scoped search — count and facets are clamped too, not just the rows
    6) scoped search — the clamp also seals the ?type= narrowing
       left: ["prpt-private"]  right: []
    7) scoped search — CANARY: a singleton public-read token is clamped identically

**This file under the same mutation — 4 named reds:**

    7 tests, 4 failures
    1) ?type= narrowing onto the private type yields an empty 200, never its rows
       left: ["idp-asset"]  right: []
    2) a mixed [public-read, read] token is clamped — 200 with an empty result, never 403
       left: ["idp-asset"]  right: []
    3) a singleton [public-read] token is clamped identically
       left: ["idp-asset"]  right: []
    4) a public-read token is clamped on the federated documents surface too

**Restored, full clamp suite green:**

    $ cd api && CC=clang MIX_ENV=test mix test \
        test/barkpark_web/integration/public_read_clamp_independent_derivation_test.exs \
        test/barkpark_web/integration/public_read_private_type_clamp_test.exs \
        test/barkpark_web/integration/public_read_search_matrix_test.exs \
        test/barkpark/search/documents_retriever_visibility_test.exs
    41 tests, 0 failures

After restore, `git status --porcelain` in the review worktree showed the new
test file as the ONLY change — the retriever is byte-identical to origin/main.

## What this derivation does NOT cover — stated so nobody reads it as wider

The **scoped media surface** (`/w/:ws/p/:proj/v1/media/:dataset*`, 10 routes on
bare `:scoped_api`) is NOT covered by this clamp, and cannot be: it reads
`media_files` blob rows via `Media.Delivery.Search`, never
`Content.search_documents`, so `restrict_anonymous_to_public_types/3` is not on
its path at all. Probed with a public-read token against a seeded blob:

- `GET .../v1/media/production/search?q=…` → 200, `total: 0`
- `GET .../v1/media/production` → 200, `count: 0`
- `GET .../v1/media/production/:id` → **200**, full blob metadata (filename,
  storage path, size, CDN + rendition URLs, `permissions: ["view", "preview",
  "use_original", "edit_metadata"]`), with `asset: null` / `assetDocId: null`.

The probe is **INCONCLUSIVE, not a clean bill**: the seeded `mediaAsset` document
WAS resolvable in-process (`Media.asset_docs_for_files/3` returned it), yet the
media doors surfaced neither it nor the blob in search/index, so the probe never
established what the media door returns when a private asset doc IS attached. It
is a lead for whoever owns the media surface, not a finding of this row, and it
should be filed as its own probe rather than block this one.

Not driven here either: the WS search channel (covered by the builder's
`search_channel_test.exs` changes in the same commit) and
`/v1/data/search/:dataset/suggestions`, which reads recorded search QUERIES via
`SearchIntelligence.suggestions/4`, not document rows — a different corpus, and
so a different question from this row's.
