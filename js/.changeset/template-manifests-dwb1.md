---
'create-barkpark-app': patch
---

Add a `barkpark.template.json` deploy descriptor to the website-starter and blog-starter templates. The manifest declares the template's framework, schemas, seed (script format, self-publishing), and the `BARKPARK_*` env each site needs — the data a deploy-button UI enumerates and a bootstrap job consumes. Spec + JSON Schema live at `templates/MANIFEST.md` / `templates/barkpark.template.schema.json`; no runtime code changed.
