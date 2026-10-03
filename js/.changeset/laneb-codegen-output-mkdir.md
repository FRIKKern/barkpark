---
'@barkpark/codegen': patch
---

`barkpark generate` now creates the `--output` file's parent directory when it does not exist. A first run into a fresh path such as `src/generated/barkpark.types.ts` used to fail with a bare `ENOENT: no such file or directory, open …`, after the schema fetch and the type generation had both succeeded. This applies to the fetch path and the network-free `--from` path.
