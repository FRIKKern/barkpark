# Denial-shape law — re-derivation recipes (arpss share-link raw-token wave, verify phase)

Base: `origin/main` @ `1984962a23c77d66af3904210eaebd055b8b0844`. All commands run from repo root
unless a `cd api` is shown.

## 1. The 404 envelope body is byte-identical for foreign-row vs missing-row

```
cd api && elixir -e '
Path.wildcard("_build/test/lib/*/ebin") |> Enum.each(&Code.append_path/1)
a = Barkpark.Content.Errors.to_envelope({:error, {:not_found, "link not found"}}, nil)
b = Barkpark.Content.Errors.to_envelope({:error, :not_found}, nil) |> Map.put(:message, "link not found")
IO.inspect(Map.delete(a, :status)); IO.inspect(Map.delete(b, :status))
IO.puts("IDENTICAL: #{inspect(a == b)}")'
```

Expected: both `%{code: "not_found", message: "link not found", hint: "Check the document _id, …"}`,
`IDENTICAL: true`. Keys are exactly `[:code, :message, :hint]` — no `details`, and `request_id` is
added only when a conn is present (from `Logger.metadata()[:request_id]`, target-independent).

## 2. The 403 envelope the scoped-admin gate already ships

```
cd api && elixir -e '
Path.wildcard("_build/test/lib/*/ebin") |> Enum.each(&Code.append_path/1)
IO.inspect(Barkpark.Content.Errors.to_envelope({:error, :forbidden}, nil))'
```

## 3. The counter-example sweep

```
grep -rn ':forbidden' api/lib/barkpark_web/plugs api/lib/barkpark_web/live | head -40
grep -rn "forbidden" api/lib/barkpark_web/controllers/*.ex | head -40
```

The one live counter-example: `api/lib/barkpark_web/controllers/access_controller.ex:95-120` —
`Access.get_grant/1` (`api/lib/barkpark/access.ex:124-129`) is a bare unscoped `Repo.get(Grant, uuid)`,
so a FOREIGN-tenant grant id answers 403 (`:106`, `:118`) while a nonexistent id answers 404 (`:100`,
`:119`). Its LiveView twin: `api/lib/barkpark_web/live/studio/studio_live/handlers/access_panel.ex:82`.

## 4. The path-address arms

```
sed -n '68,80p;125,140p' api/lib/barkpark_web/plugs/resolve_workspace.ex
sed -n '1,45p' api/lib/barkpark_web/plugs/require_workspace_role.ex
```

`resolve_workspace.ex:76` = unknown path slug → 404. `:134` = existing path slug, not a member → 403.
`require_workspace_role.ex:30` = existing path slug, member but not admin → 403, via
`TenancyAuth.workspace_admin?/2` and the canonical `Errors.to_envelope({:error, :forbidden})` envelope.

## 5. The content-plane 404 witness (#12347, MERGED, test-only)

```
gh pr diff 12347 --name-only
gh pr diff 12347 | grep -n 'assert resp_plain.status'
```
