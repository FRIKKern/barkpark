---
'@barkpark/react': patch
---

Status-vocabulary hardening against manifest drift: the legend ladder is now derived as "every role but the fail-open `unknown` sentinel" instead of filtering through a second hand-maintained role-name list, and a new parity test compares the package's whole status mapping — aliases and terminal states (`closed`→done, `cancelled`→cancel), the `default_role` fallback, spinner/meaning on every legend row, and the sentinel — against `design/status-manifest.json`, the one canonical vocabulary. Rendered output is unchanged.
