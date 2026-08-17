# cch-w70 post-merge anchor sweep — re-derivation recipe

Baseline: origin/main @ d020382028e3155e5d1e73d2df1b75f8416060fe (#11783 merge tip).

## Re-derive every anchor

```
git fetch origin
git show origin/main:cloud/priv/static/app.js | grep -nE 'function (friendly|siteCreateFailureCopy|siteRollbackFailure|siteDeleteFailureCopy|siteReadableTypesMenu|siteDetailWithoutCliReRun)\('
git show origin/main:cloud/priv/static/__app.test.mjs | grep -n 'friendly.length'
git show origin/main:cloud/priv/static/__app.test.mjs | grep -n 'cch-w30-s5'
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n 'defp rollback_refusal\|defp teardown_refusal\|defp refusal_detail\|defp refusal_code'
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'mint_failure_copy\|HARD MATCH, DELIBERATE\|content_binding_required\|content_binding_empty\|delete "/v1/sites/:id"\|{:error, status, detail, code} ->'
```

## Resolved anchors (function name + current origin/main line)

| Anchor | File | Line | Matched text |
|---|---|---|---|
| friendly | app.js | 346 | `function friendly(data, fallback) {` |
| siteReadableTypesMenu | app.js | 9654 | `function siteReadableTypesMenu(types) {` |
| siteDetailWithoutCliReRun | app.js | 9667 | `function siteDetailWithoutCliReRun(detail) {` |
| siteCreateFailureCopy | app.js | 9707 | `function siteCreateFailureCopy(r) {` |
| siteRollbackFailure | app.js | 13313 | `function siteRollbackFailure(status, data) {` |
| siteDeleteFailureCopy | app.js | 13518 | `function siteDeleteFailureCopy(status, data) {` |
| friendly arity pin | __app.test.mjs | 18107 | `assert.equal(hooks.friendly.length, 2, ...)` |
| w30-s5 nested pin | __app.test.mjs | 16492-16494 | `const nested = { error: { code: "server_error" } };` → asserts friendly falls back |
| refusal_code | deploy.ex | 1658 | `defp refusal_code(%{"error" => %{} = err}), do: string_or_nil(err["code"])` |
| refusal_detail (nested) | deploy.ex | 1675 | `defp refusal_detail(%{"error" => %{} = err}) do` |
| refusal_detail (flat) | deploy.ex | 1689 | `defp refusal_detail(body), do: body["error"] \|\| body["detail"] \|\| body["reason"] \|\| body["failure_reason"]` |
| rollback_refusal | deploy.ex | 1905 | `defp rollback_refusal(body, fallback) when is_map(body) do` |
| teardown_refusal | deploy.ex | 1923 | `defp teardown_refusal(body, fallback) when is_map(body) do` |
| mint_failure_copy | router.ex | 12517 | `defp mint_failure_copy(bp, {:instance, status, body}) do` (body chain @12518, NO failure_reason) |
| delete /v1/sites/:id | router.ex | 7104 | `delete "/v1/sites/:id" do` |
| D820 HARD MATCH block | router.ex | 7111 | `# HARD MATCH, DELIBERATE, AND IT HAS A PRICE (W67 S2 / D820).` |
| bare Repo.delete | router.ex | 7127 | `{:ok, _} = Registry.delete_site(site)` |
| sibling relay arm | router.ex | 7152 | `{:error, status, detail, code} -> json(conn, status, %{ok: false, error: code, detail: detail})` |
| teardown_failed default arm | router.ex | 7155 | `{:error, status, detail} -> json(conn, status, %{ok: false, error: "teardown_failed", detail: detail})` |
| content_binding_required | router.ex | 6925 | `error: "content_binding_required"` (detail names `--dataset <workspace>/<project>/<dataset>`) |
| content_binding_empty | router.ex | 6950 | `%{error: "content_binding_empty", detail: detail} \|> maybe_put_menu(menu)` |

## Chain-class note (feeds S4 / V6)

Three structurally-identical discarding chains confirmed:
- deploy.ex refusal_detail flat clause (1689): reads error/detail/reason/**failure_reason** — the SECOND chain smoke flagged.
- router.ex mint_failure_copy `{:instance,status,body}` (12518): reads error/detail/reason, NO failure_reason, and the head only matches a FLAT `{:instance,status,body}` — a nested `{"error":{...}}` body discards. THIRD chain, different file (strains D847 one-file claim).
