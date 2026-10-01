---
'@barkpark/codegen': patch
---

The `barkpark` CLI now exits 1 on a mistyped or missing command, with an "unknown command" line or the help. It used to print nothing and exit 0, so a CI step running `barkpark genrate` "passed" without writing any types. `--version` now prints the package version.
