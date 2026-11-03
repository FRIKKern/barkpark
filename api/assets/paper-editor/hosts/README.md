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

Strict mode exits nonzero while any E01–E12 journey is unavailable. During
incremental development, `--allow-unavailable` writes the partial artifacts and
`hosts/manifest.json`; the manifest remains `incomplete`, so it cannot be
mistaken for acceptance evidence. `--host=<id>` narrows a local run to one host.

Current executable journeys are E01–E08 and E10–E12 (E11 is Studio-only and
E12 requires a candidate). The manifest gives a concrete reason for
every unavailable journey. E09 remains unavailable until TG2's sixth Read≠Edit
light and known-red proof land under `task-53f2fc33b834114f`.
