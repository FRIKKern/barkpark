<!-- doc-tier: human | canonical-for: self-host-copy | budget: 1000tok -->
# Copy one dataset over the API

Use this when you cannot reach the source's database or servers. It needs a token that reads the source and writes the target. Run the commands in this order:

```bash
bp -s <target> workspace create <ws> --slug <ws>
bp -s <source> -w <ws> -d production export --out backup.ndjson --media media --schemas schemas.json
bp -s <target> -w <ws> -d production import backup.ndjson --media media --schemas schemas.json --dry-run
bp -s <target> -w <ws> -d production import backup.ndjson --media media --schemas schemas.json
```

- The target needs the workspace before the import. Skip the first command when it exists. Attach it to an organization and add members as for any new workspace.
- `export --schemas <file>` writes every schema of the dataset to one file. `import --schemas <file>` applies them before any media or document. The first schema creates the dataset, so it needs no separate step. Each apply replaces the schema of that name, so a re-run is safe. A 429 waits for the server's `Retry-After`. Compare the two sides as [SELF-HOST-MOVE.md](SELF-HOST-MOVE.md#compare-schemas) says.

- To copy part of a dataset, name its document types: `export --type post,author --schemas schemas.json`. Each type is one request. `--schemas` then writes only the schemas of those types. The filter does not follow references, so name every type the copied documents point at, such as `mediaAsset` for their images. `--media` still writes every file of the dataset.
- `export --media <dir>` writes every media file to `<dir>/files/<id>` and lists ids and SHA-1s in `<dir>/media.json`. A re-run skips files it already holds.
- `import --media <dir>` uploads each file with `mediaFileId`, so the target keeps the asset id, the SHA-1 and each `asset-<id>` document. Byte duplicates keep their own ids. The exported `mediaAsset` rows then replace the documents the uploads made, with `fileInfo.path` pointing at the target's copy. A `/media/files/<path>` URL stored in other content still names the source's path.
- The import writes each document as exported. The target adds no schema initial values and derives no title. A target older than this answers with a warning, and its creates still add them.
- A batch the target cannot finish in time is sent again at half its documents, down to one. The report names the size it ended with. A stopped import prints `--from-line N`.
- `import --media` skips each file the target lists with the same id, size and SHA-1, so a resumed run sends only the rest. An id the target holds with other bytes refuses it unless `--replace-media` is set.
- A file stored before 2026-10-10 lacks a SHA-1 until a backfill. Both commands check and count it by size.
- An older target ignores `mediaFileId` and stores a new id. The import then stops at the first file, before any document.
- Media file ids are unique per instance. An import with `--media` into a second dataset on the same instance is refused with 409 at the first file, so copy media to another instance.
- Empty the target first with `bp -s <target> -w <ws> -p <project> dataset empty production --confirm-production production`. It keeps the dataset and schemas.
