---
'@barkpark/core': patch
---

Export `GetDocOptions`, `DocResult`, and `DocsOperationOptions` — the option/result types for the (already-exported) `getDoc` (`opts` / return) and `createDocsOperation` (`opts`) escape-hatch functions. They were defined but not re-exported, so a consumer using those functions directly couldn't type their args/returns. Continues the listen-options fix as a small exports-completeness sweep.
