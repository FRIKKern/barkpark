# Host journey capture

`npm run hosts` drives the real testing-ground editor through seven synthetic host
shells. It accepts test documents only. The host registry records the production
integration source each shell represents; it does not start the native apps.

The runner requires Chrome for Testing `148.0.7778.167` exactly. By default it
uses Puppeteer's platform cache. Set `CHROME_HEADLESS_SHELL` to an absolute path
when the exact binary lives elsewhere. GIF creation uses `ffmpeg` from `PATH` or
`HOSTS_FFMPEG`.

Artifacts default to `hosts/artifacts/{hosts,journeys}`. Use an explicit output
root when producing the portable-doc evidence set:

```sh
npm run hosts -- --output=/path/to/portable-doc/docs/images
```

E12 also needs an explicit staged editor build. The directory must contain a
full `source-commit`, `SHA256SUMS`, and the three browser bundle files. Every
listed checksum is verified before either server or Chrome starts:

```sh
npm run hosts -- --candidate=/path/to/staged-editor --output=/path/to/portable-doc/docs/images
```

The candidate bundle must differ from the committed baseline bundle. During
the replay, Chromium fetches and hashes each served bundle; the E12 report
records those browser-observed identities and refuses a source or digest
mismatch before comparing the two normalized save logs.

For the preserved 1.21→1.22 retro pair, pass both verified directories:

```sh
npm run hosts -- --baseline=/path/to/served-1.21 --candidate=/path/to/staged-1.22 --output=/path/to/portable-doc/docs/images
```

The same full `source-commit` and checksum contract applies to an explicit
baseline. This historical A/B replay is separate from a native host's
same-backend upgrade or rollback evidence.

`npm run host:restore` covers that separate rollback case. It verifies an exact
packaged candidate, maps all six package assets, then switches a loopback
Barkpark host from the candidate to a preserved served baseline. One disposable
Paper backend stays alive across both phases. The reader, web, and Studio field
routes record their browser-loaded asset hashes; candidate and restored clients
must each save and reload the same Paper:

```sh
npm run host:restore -- \
  --candidate-tarball=/path/to/portable-doc-editor.tgz \
  --candidate-sha256=<sha256> \
  --baseline=/path/to/preserved-served-assets \
  --output=/path/to/evidence
```

The runner binds only to loopback and does not read tokens or production
configuration.

Strict mode exits nonzero while any E01–E12 journey is unavailable. During
incremental development, `--allow-unavailable` writes the partial artifacts and
`hosts/manifest.json`; the manifest remains `incomplete`, so it cannot be
mistaken for acceptance evidence. `--host=<id>` narrows a local run to one host.

All E01–E12 journeys are executable (E11 is Studio-only and E12 requires a
candidate). E09 is intentionally a diagnostic negative: it passes only when
TG2's Read/Edit light settles red on the frozen `sample:callout` mismatch and
records that known-red screenshot. It is evidence that the detector works,
not evidence that reader/editor parity is green. The manifest labels this
distinction explicitly.
