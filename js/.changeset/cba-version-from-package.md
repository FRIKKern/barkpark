---
'create-barkpark-app': patch
---

`create-barkpark-app --version` now prints the package's own version. The build used to inject a hard-coded `1.0.0-preview.0`, so the published `1.0.0-preview.1` reported the wrong version.
