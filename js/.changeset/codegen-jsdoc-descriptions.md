---
'@barkpark/codegen': minor
---

Generated types now carry JSDoc comments from each schema/field's `description` (falling back to its `title`), so consumers get hover documentation in the editor — matching what comparable schema-codegen tools emit. Fields with neither are unchanged. Comment text is collapsed to a single line and a literal `*/` is neutralized so it can never close the comment early and break compilation.
