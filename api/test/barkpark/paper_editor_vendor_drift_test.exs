defmodule Barkpark.PaperEditorVendorDriftTest do
  @moduledoc """
  The DRIFT TRIPWIRE for the vendored `bp-paper-editor` Web Component artifacts.

  `api/assets/paper-editor/` builds ONE pair of committed artifacts into
  `api/priv/static/assets/`, and its own `build:web` npm script then copies that
  pair into `web/public/` so the Next.js demo can `<script src>` the same
  component Phoenix serves. Both copies are committed; `build:web` is the only
  thing that keeps them equal, and NOTHING invoked it — no CI job, no Makefile
  target, no hook. Measured on main: `grep -rn "build:web"` across `*.yml`,
  `*.yaml`, `Makefile` and `*.sh` returned nothing at all.

  So they drifted, in committed files, for months: at `0b0bda6807` the api
  bundle was rebuilt 2026-08-31 alongside `src/`, while `web/public`'s JS copy
  was last synced 2026-07-31 and its CSS copy 2026-07-07 — the api side had
  taken 58 commits to the web side's 38. The demo was mounting a one-month-old
  component against an eight-week-old stylesheet, and every gate was green.

  This is the same shape as the vendored deployable app trees, and the same
  remedy: `cloud/test/barkpark_cloud/templates/app_files_drift_test.exs` pins
  `cloud/priv/templates/**` byte-for-byte against its
  `js/packages/create-barkpark-app/templates/**` source. Read that one first —
  this is its sibling.

  ## What this DOES catch

  A rebuild of the api artifacts that ships without the `build:web` copy — the
  failure that actually happened, and the one that recurs every time someone
  touches the editor. Both pairs are checked: the `.js` and the `.css` drifted
  on DIFFERENT dates, so a guard on the bundle alone would have gone green
  across eight weeks of stylesheet drift.

  ## What this does NOT catch (stated, not implied)

  It does not rebuild from source, so it cannot see an edit to
  `api/assets/paper-editor/src/` that was never built into EITHER copy. That
  would need a reproducible build, and the build is not reproducible here:
  `esbuild` is pinned as `^0.24.2`, a caret range, so a fresh `npm install` can
  minify to different bytes and red this suite for a reason that is not drift.
  A gate that reds on its own toolchain teaches people to ignore it. This one
  asserts the invariant `build:web` establishes — the two committed copies are
  equal — and says so rather than implying more.

  ## Why it lives here, in the Elixir suite

  Main's required contexts are exactly `Elixir gate`, `PR references an active
  task`, `Cloud gate` and `Console gate`. `ci.yml` (which runs web/'s tests) is
  path-filtered to `web/**`, so a PR that rebuilds ONLY the api artifacts — the
  precise commit that creates this drift — does not trigger it at all, and it
  does not block a merge even when it does run. `elixir.yml` carries no
  workflow-level paths key by design, and its compile set is `api/**`, which
  includes `api/priv/static/assets/**`. This is the only home where the guard
  both SEES the drifting commit and can STOP it.

  The two `web/public` reads are declared in `ELIXIR_TEST_ONLY_PATHS` in
  `scripts/elixir-path-escape-check.sh` — the sanctioned door, per that file's
  own rule that the honest fix for a cross-tree read is to declare it, not to
  exempt it. Declaring them also buys the other direction: a PR that edits only
  the vendored web copy now runs this suite too, so neither side can be moved
  alone.

  Re-sync with `cd api/assets/paper-editor && npm run build:web`.
  """
  use ExUnit.Case, async: true

  # Spelled as FOUR literal `Path.expand("../../../…", __DIR__)` reads, matching
  # the idiom in `preview_parity_fixture_test.exs` and `sheets_parity_test.exs`.
  # That spelling is load-bearing, not style: `scripts/elixir-path-escape-check.sh`
  # resolves `"../…"` STRING LITERALS, so building these paths from a
  # `@repo_root` attribute plus `Path.join/2` would hide the leaves from the
  # ratchet and this suite would quietly evade the dispatch declaration it
  # depends on. (Measured: with the joined spelling the ratchet reported
  # "OK: every repo-root read … is dispatched on" while these two web/ reads
  # existed and were undeclared.)
  @canonical_js Path.expand("../../priv/static/assets/bp-paper-editor.bundle.js", __DIR__)
  @vendored_js Path.expand("../../../web/public/bp-paper-editor.bundle.js", __DIR__)
  @canonical_css Path.expand("../../priv/static/assets/bp-paper-editor.css", __DIR__)
  @vendored_css Path.expand("../../../web/public/assets/bp-paper-editor.css", __DIR__)

  @pairs [
    {"bundle JS", @canonical_js, @vendored_js},
    {"stylesheet", @canonical_css, @vendored_css}
  ]

  @resync "cd api/assets/paper-editor && npm run build:web"

  # Report paths repo-relative so a CI failure reads like the repo, not like a
  # runner's absolute checkout path.
  defp rel(path), do: Path.relative_to(path, Path.expand("../../..", __DIR__))

  test "every vendored bp-paper-editor artifact exists on both sides" do
    for {label, canonical, vendored} <- @pairs do
      assert File.exists?(canonical),
             "#{label}: canonical #{rel(canonical)} is missing — the api build output is the source of truth"

      assert File.exists?(vendored),
             "#{label}: vendored #{rel(vendored)} is missing — run `#{@resync}`"
    end
  end

  test "every vendored bp-paper-editor artifact is byte-identical to the api build output" do
    # Every pair is compared and the mismatches are reported TOGETHER, rather
    # than asserting inside the loop. Asserting per-pair aborts at the first
    # failure, and these two artifacts drift INDEPENDENTLY — on main the bundle
    # was last synced 2026-07-31 and the stylesheet 2026-07-07. A guard that
    # reveals the second drift only after you have fixed the first is a guard
    # that hides half of what it knows.
    drifted =
      for {label, canonical, vendored} <- @pairs,
          canonical_bytes = File.read!(canonical),
          vendored_bytes = File.read!(vendored),
          canonical_bytes != vendored_bytes do
        """
          #{label}: #{rel(vendored)} has DRIFTED from #{rel(canonical)}
            #{rel(canonical)}: #{byte_size(canonical_bytes)} bytes
            #{rel(vendored)}: #{byte_size(vendored_bytes)} bytes\
        """
      end

    assert drifted == [],
           """
           #{length(drifted)} of #{length(@pairs)} vendored bp-paper-editor artifact(s) drifted:

           #{Enum.join(drifted, "\n")}
           The api copy is the build output and the source of truth; the web copy
           is a vendored duplicate that only `build:web` keeps equal. Re-sync with:

             #{@resync}

           Committing a rebuilt api artifact without that copy is what this
           tripwire exists to stop — it is how the two sides spent months apart.
           """
  end
end
