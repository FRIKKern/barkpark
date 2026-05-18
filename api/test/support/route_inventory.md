# Barkpark route inventory

Generated: 2026-05-18
Source: api/lib/barkpark_web/router.ex (commit 7beecb3a5bc480b16876eef155cad4d87d5f914d)

Cross-checked against `mix phx.routes` (commit above). Phoenix LiveDashboard
routes under `/dev/dashboard` and the LiveView socket transports at
`/live/websocket` and `/live/longpoll` are excluded — neither belongs to
application surface and the dashboard is dev-only (`Application.compile_env(:barkpark, :dev_routes)`).

The "Test coverage" column uses three values:

- **yes**     — at least one test file exercises the route via HTTP and is ≥ 50 LOC.
- **partial** — a test file exists but is < 50 LOC, exercises only a subset of the
                route's actions, or hits the controller function in isolation
                rather than driving the full HTTP pipeline.
- **no**      — no test file references the controller / LV module or the route path.

## :browser pipeline (LiveView + HTML)

Plug stack: `accepts ["html"]` → `fetch_session` → `fetch_live_flash` →
`put_root_layout` → `protect_from_forgery` → `put_secure_browser_headers`.
Most LV routes layer an `on_mount` auth hook on top: `LiveAuth.:admin`,
`LiveAuth.:ops`, or `LiveAuth.:fetch_api_token`.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET  | /                                           | PageController:redirect_to_studio       | none                 | partial (page_controller_test.exs, 13 LOC) |
| GET  | /studio                                     | PageController:redirect_to_studio       | none                 | partial (page_controller_test.exs, 13 LOC) |
| GET  | /login                                      | SessionController:new                   | none                 | yes (session_controller_test.exs, 121 LOC) |
| POST | /login                                      | SessionController:create                | session              | yes (session_controller_test.exs, 121 LOC) |
| POST | /logout                                     | SessionController:delete                | session              | yes (session_controller_test.exs, 121 LOC) |
| GET  | /studio/settings                            | Studio.SettingsLive                     | LiveAuth.:admin      | yes (settings_live_test.exs, 225 LOC) |
| GET  | /admin/bokbasen                             | Admin.BokbasenLive                      | LiveAuth.:ops        | yes (bokbasen_live_test.exs, 187 LOC) |
| GET  | /admin/onixedit/staleness                   | Admin.OnixeditStalenessLive:index       | LiveAuth.:ops        | yes (onixedit_staleness_live_test.exs, 241 LOC) |
| GET  | /studio/:dataset/onixedit/book/:doc_id      | OnixeditRedirectController:show         | none                 | partial (onixedit_redirect_controller_test.exs, 37 LOC) |
| GET  | /studio/:dataset/onixedit/book/:doc_id/view | OnixeditRedirectController:show         | none                 | partial (onixedit_redirect_controller_test.exs, 37 LOC) |
| GET  | /studio/:dataset/_plugins                   | Admin.PluginsLive                       | LiveAuth.:admin      | yes (plugins_live_test.exs, 136 LOC) |
| GET  | /studio/:dataset/_plugins/:plugin/settings  | Admin.PluginSettingsLive                | LiveAuth.:admin      | yes (plugin_settings_live_test.exs, 283 LOC) |
| GET  | /studio/:dataset                            | Studio.StudioLive                       | LiveAuth.:fetch_api_token | yes (studio_live_editor_test.exs 258 LOC + studio_live_array_op_test.exs 472 LOC + studio_live_doc_actions_test.exs 171 LOC) |
| GET  | /studio/:dataset/media                      | Studio.MediaLive                        | LiveAuth.:fetch_api_token | no |
| GET  | /studio/:dataset/_api                       | Admin.ApiTestRunnerLive                 | LiveAuth.:admin           | partial (api_test_runner_live_test.exs exercises mount + run_all events) |
| GET  | /studio/:dataset/*path                      | Studio.StudioLive                       | LiveAuth.:fetch_api_token | yes (rolled into the StudioLive tests above — the catch-all is the same module) |

## :api pipeline — public reads (JSON, optional token)

Plug stack: `AcceptBarkparkVendor` → `accepts ["json"]` → `ErrorEnvelopeNegotiation`
→ `RateLimit` → `OptionalToken`. The optional token elevates visibility
(private schemas appear with auth) but is not required.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET | /v1/data/search/:dataset            | SearchController:search   | optional token | yes (search_test.exs, 85 LOC) |
| GET | /v1/data/query/:dataset/:type       | QueryController:index     | optional token | yes (query_test.exs 91 LOC + filter_ops/filter_response/expand/accept_vendor contract tests) |
| GET | /v1/data/doc/:dataset/:type/:doc_id | QueryController:show      | optional token | yes (query_controller_book_test.exs, 128 LOC) |

## :api_unlimited pipeline — meta (no token, no rate limit)

Plug stack: `accepts ["json"]` → `ErrorEnvelopeNegotiation`.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET | /v1/meta | MetaController:index | none | partial (meta_test.exs, 43 LOC) |

## :api_preview pipeline — preview reads (preview JWT)

Plug stack: `AcceptBarkparkVendor` → `accepts ["json"]` → `ErrorEnvelopeNegotiation`
→ `RateLimit` → `PreviewToken`. Forces `perspective=drafts` via the
preview JWT carried in the `Authorization: Preview <jwt>` header.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET | /v1/preview/query/:dataset/:type       | QueryController:index | preview JWT | no (only the PreviewToken plug is tested in isolation — no end-to-end route test) |
| GET | /v1/preview/doc/:dataset/:type/:doc_id | QueryController:show  | preview JWT | no (same as above) |

## :api + :require_token pipeline — private reads (JSON, token required)

Plug stack: `:api` ∪ `RequireToken`.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET  | /v1/data/listen/:dataset                  | ListenController:listen   | token | partial (listen_test.exs 63 LOC, but it calls `replay_since/2` directly — no SSE HTTP round-trip) |
| GET  | /v1/data/export/:dataset                  | ExportController:export   | token | yes (export_test.exs, 57 LOC — slightly above the gate; functional ndjson coverage) |
| GET  | /v1/data/analytics/:dataset               | AnalyticsController:index | token | yes (analytics_test.exs, 60 LOC) |
| GET  | /v1/data/history/:dataset/:type/:doc_id   | HistoryController:index   | token | yes (history_test.exs, 126 LOC) |
| GET  | /v1/data/revision/:dataset/:id            | HistoryController:show    | token | yes (history_test.exs covers all three history/revision actions) |
| POST | /v1/data/revision/:dataset/:id/restore    | HistoryController:restore | token | yes (history_test.exs) |

## :api + :require_token + :idempotent pipeline — mutations

Plug stack: `:api` ∪ `RequireToken` ∪ `Idempotency`. Idempotency dedups by
`Idempotency-Key` header; replays return the original response body verbatim.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| POST | /v1/data/mutate/:dataset | MutateController:mutate | token + idempotency | yes (mutate_test.exs 152 LOC + mutate_controller_test.exs 96 LOC; idempotency_test.exs 159 LOC layers replay assertions) |

## :api + :require_admin pipeline — admin-only (JSON, admin token)

Plug stack: `:api` ∪ `RequireToken` ∪ `RequireAdmin`.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET    | /v1/schemas/:dataset                     | SchemaController:index            | admin | partial (schema_test.exs 38 LOC + schema_envelope_test.exs 135 LOC — index covered, envelope wrapper covered) |
| GET    | /v1/schemas/:dataset/:name               | SchemaController:show             | admin | partial (schema_test.exs covers show but is 38 LOC) |
| POST   | /v1/schemas/:dataset                     | SchemaController:upsert           | admin | no (no test issues a POST against /v1/schemas/:dataset) |
| DELETE | /v1/schemas/:dataset/:name               | SchemaController:delete           | admin | no |
| GET    | /v1/plugins/settings/:plugin_name        | PluginSettingsController:show     | admin | yes (plugin_settings_controller_test.exs, 99 LOC) |
| PUT    | /v1/plugins/settings/:plugin_name        | PluginSettingsController:update   | admin | yes (plugin_settings_controller_test.exs covers PUT roundtrip) |
| DELETE | /v1/plugins/settings/:plugin_name        | PluginSettingsController:delete   | admin | yes (plugin_settings_controller_test.exs covers DELETE) |
| GET    | /v1/plugins/onixedit/export/:dataset/:id | OnixeditExportController:show     | admin | yes (onixedit_export_controller_test.exs, 145 LOC) |
| GET    | /v1/webhooks/:dataset                    | WebhookController:index           | admin | yes (webhooks_test.exs, 73 LOC — full CRUD lifecycle) |
| GET    | /v1/webhooks/:dataset/:id                | WebhookController:show            | admin | yes (webhooks_test.exs) |
| POST   | /v1/webhooks/:dataset                    | WebhookController:create          | admin | yes (webhooks_test.exs) |
| PUT    | /v1/webhooks/:dataset/:id                | WebhookController:update          | admin | yes (webhooks_test.exs) |
| DELETE | /v1/webhooks/:dataset/:id                | WebhookController:delete          | admin | yes (webhooks_test.exs) |

## /media — :api pipeline (read) + :require_token (write)

Plug stack for read: `:api` (optional token). Plug stack for write: `:api` ∪ `RequireToken`.

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET    | /media               | MediaController:index   | optional token | no |
| GET    | /media/:id/meta      | MediaController:show    | optional token | no |
| GET    | /media/files/*path   | MediaController:serve   | optional token | no |
| POST   | /media/upload        | MediaController:upload  | token          | no |
| DELETE | /media/:id           | MediaController:delete  | token          | no |

## /api — legacy pipeline (deprecated, JSON)

Plug stack: `:api` ∪ `BarkparkWeb.Plugs.LegacyDeprecation` (injects
`Deprecation: true` + `Sunset` + `Link` headers).

| Method | Path | Module:Action | Auth | Test coverage |
|---|---|---|---|---|
| GET    | /api/documents/:type     | LegacyController:index   | optional token | no |
| GET    | /api/documents/:type/:id | LegacyController:show    | optional token | no |
| POST   | /api/documents/:type     | LegacyController:create  | optional token | no |
| DELETE | /api/documents/:type/:id | LegacyController:delete  | optional token | no |
| GET    | /api/schemas             | LegacyController:schemas | optional token | partial (legacy_headers_test.exs 10 LOC — header-only smoke; schema_envelope_test.exs 135 LOC also touches this path for envelope assertions) |

## Summary

- **Total application routes**: 52 (excludes `/dev/dashboard*` LiveDashboard and `/live/*` socket transports).
- **yes**     : 29
- **partial** : 9
- **no**      : 14

Routes with **no** coverage are concentrated in two surfaces:

1. **The entire `/media` surface** — five routes, including the only file upload
   path (`POST /media/upload`) and the file-serving fallthrough
   (`GET /media/files/*path`). High-impact gap.
2. **The entire `/api/documents/*` legacy CRUD surface** — four routes used
   by the Go TUI for backward compatibility. The legacy `GET /api/schemas`
   is partially covered (deprecation headers only).
3. **`POST /v1/schemas/:dataset` and `DELETE /v1/schemas/:dataset/:name`** —
   admin-only schema mutation surface; no integration test fires either.
4. **Preview routes** `/v1/preview/{query,doc}/...` — the `PreviewToken` plug
   is unit-tested in isolation but no test drives the full HTTP route.
5. **`/studio/:dataset/media`** (`Studio.MediaLive`) — the LiveView itself
   has no test (the underlying `Barkpark.Media` context may have tests in
   `barkpark/` but the LV mount path is untested).

```json
{
  "generated": "2026-05-18",
  "router_source": "api/lib/barkpark_web/router.ex",
  "router_commit": "7beecb3a5bc480b16876eef155cad4d87d5f914d",
  "routes": [
    {"method": "GET",    "path": "/",                                              "pipeline": "browser",                            "module": "BarkparkWeb.PageController",            "action": "redirect_to_studio", "auth": "none",                  "test_coverage": "partial"},
    {"method": "GET",    "path": "/studio",                                        "pipeline": "browser",                            "module": "BarkparkWeb.PageController",            "action": "redirect_to_studio", "auth": "none",                  "test_coverage": "partial"},
    {"method": "GET",    "path": "/login",                                         "pipeline": "browser",                            "module": "BarkparkWeb.SessionController",         "action": "new",                "auth": "none",                  "test_coverage": "yes"},
    {"method": "POST",   "path": "/login",                                         "pipeline": "browser",                            "module": "BarkparkWeb.SessionController",         "action": "create",             "auth": "session",               "test_coverage": "yes"},
    {"method": "POST",   "path": "/logout",                                        "pipeline": "browser",                            "module": "BarkparkWeb.SessionController",         "action": "delete",             "auth": "session",               "test_coverage": "yes"},
    {"method": "GET",    "path": "/studio/settings",                               "pipeline": "browser+admin_studio",               "module": "BarkparkWeb.Studio.SettingsLive",       "action": null,                 "auth": "LiveAuth.:admin",       "test_coverage": "yes"},
    {"method": "GET",    "path": "/admin/bokbasen",                                "pipeline": "browser+admin_ops",                  "module": "BarkparkWeb.Admin.BokbasenLive",        "action": null,                 "auth": "LiveAuth.:ops",         "test_coverage": "yes"},
    {"method": "GET",    "path": "/admin/onixedit/staleness",                      "pipeline": "browser+admin_ops",                  "module": "BarkparkWeb.Admin.OnixeditStalenessLive","action": "index",             "auth": "LiveAuth.:ops",         "test_coverage": "yes"},
    {"method": "GET",    "path": "/studio/:dataset/onixedit/book/:doc_id",         "pipeline": "browser",                            "module": "BarkparkWeb.OnixeditRedirectController","action": "show",              "auth": "none",                  "test_coverage": "partial"},
    {"method": "GET",    "path": "/studio/:dataset/onixedit/book/:doc_id/view",    "pipeline": "browser",                            "module": "BarkparkWeb.OnixeditRedirectController","action": "show",              "auth": "none",                  "test_coverage": "partial"},
    {"method": "GET",    "path": "/studio/:dataset/_plugins",                      "pipeline": "browser+admin_studio_dataset",       "module": "BarkparkWeb.Admin.PluginsLive",         "action": null,                 "auth": "LiveAuth.:admin",       "test_coverage": "yes"},
    {"method": "GET",    "path": "/studio/:dataset/_plugins/:plugin/settings",     "pipeline": "browser+admin_studio_dataset",       "module": "BarkparkWeb.Admin.PluginSettingsLive",  "action": null,                 "auth": "LiveAuth.:admin",       "test_coverage": "yes"},
    {"method": "GET",    "path": "/studio/:dataset",                               "pipeline": "browser+studio_public",              "module": "BarkparkWeb.Studio.StudioLive",         "action": null,                 "auth": "LiveAuth.:fetch_api_token","test_coverage": "yes"},
    {"method": "GET",    "path": "/studio/:dataset/media",                         "pipeline": "browser+studio_public",              "module": "BarkparkWeb.Studio.MediaLive",          "action": null,                 "auth": "LiveAuth.:fetch_api_token","test_coverage": "no"},
    {"method": "GET",    "path": "/studio/:dataset/_api",                          "pipeline": "browser+admin_studio_dataset",       "module": "BarkparkWeb.Admin.ApiTestRunnerLive",   "action": null,                 "auth": "LiveAuth.:admin",       "test_coverage": "partial"},
    {"method": "GET",    "path": "/studio/:dataset/*path",                         "pipeline": "browser+studio_public",              "module": "BarkparkWeb.Studio.StudioLive",         "action": null,                 "auth": "LiveAuth.:fetch_api_token","test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/meta",                                       "pipeline": "api_unlimited",                      "module": "BarkparkWeb.MetaController",            "action": "index",              "auth": "none",                  "test_coverage": "partial"},
    {"method": "GET",    "path": "/v1/data/search/:dataset",                       "pipeline": "api",                                "module": "BarkparkWeb.SearchController",          "action": "search",             "auth": "optional",              "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/data/query/:dataset/:type",                  "pipeline": "api",                                "module": "BarkparkWeb.QueryController",           "action": "index",              "auth": "optional",              "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/data/doc/:dataset/:type/:doc_id",            "pipeline": "api",                                "module": "BarkparkWeb.QueryController",           "action": "show",               "auth": "optional",              "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/preview/query/:dataset/:type",               "pipeline": "api_preview",                        "module": "BarkparkWeb.QueryController",           "action": "index",              "auth": "preview-jwt",           "test_coverage": "no"},
    {"method": "GET",    "path": "/v1/preview/doc/:dataset/:type/:doc_id",         "pipeline": "api_preview",                        "module": "BarkparkWeb.QueryController",           "action": "show",               "auth": "preview-jwt",           "test_coverage": "no"},
    {"method": "GET",    "path": "/v1/data/listen/:dataset",                       "pipeline": "api+require_token",                  "module": "BarkparkWeb.ListenController",          "action": "listen",             "auth": "token",                 "test_coverage": "partial"},
    {"method": "GET",    "path": "/v1/data/export/:dataset",                       "pipeline": "api+require_token",                  "module": "BarkparkWeb.ExportController",          "action": "export",             "auth": "token",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/data/analytics/:dataset",                    "pipeline": "api+require_token",                  "module": "BarkparkWeb.AnalyticsController",       "action": "index",              "auth": "token",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/data/history/:dataset/:type/:doc_id",       "pipeline": "api+require_token",                  "module": "BarkparkWeb.HistoryController",         "action": "index",              "auth": "token",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/data/revision/:dataset/:id",                 "pipeline": "api+require_token",                  "module": "BarkparkWeb.HistoryController",         "action": "show",               "auth": "token",                 "test_coverage": "yes"},
    {"method": "POST",   "path": "/v1/data/revision/:dataset/:id/restore",         "pipeline": "api+require_token",                  "module": "BarkparkWeb.HistoryController",         "action": "restore",            "auth": "token",                 "test_coverage": "yes"},
    {"method": "POST",   "path": "/v1/data/mutate/:dataset",                       "pipeline": "api+require_token+idempotent",       "module": "BarkparkWeb.MutateController",          "action": "mutate",             "auth": "token+idempotency",     "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/schemas/:dataset",                           "pipeline": "api+require_admin",                  "module": "BarkparkWeb.SchemaController",          "action": "index",              "auth": "admin",                 "test_coverage": "partial"},
    {"method": "GET",    "path": "/v1/schemas/:dataset/:name",                     "pipeline": "api+require_admin",                  "module": "BarkparkWeb.SchemaController",          "action": "show",               "auth": "admin",                 "test_coverage": "partial"},
    {"method": "POST",   "path": "/v1/schemas/:dataset",                           "pipeline": "api+require_admin",                  "module": "BarkparkWeb.SchemaController",          "action": "upsert",             "auth": "admin",                 "test_coverage": "no"},
    {"method": "DELETE", "path": "/v1/schemas/:dataset/:name",                     "pipeline": "api+require_admin",                  "module": "BarkparkWeb.SchemaController",          "action": "delete",             "auth": "admin",                 "test_coverage": "no"},
    {"method": "GET",    "path": "/v1/plugins/settings/:plugin_name",              "pipeline": "api+require_admin",                  "module": "BarkparkWeb.PluginSettingsController",  "action": "show",               "auth": "admin",                 "test_coverage": "yes"},
    {"method": "PUT",    "path": "/v1/plugins/settings/:plugin_name",              "pipeline": "api+require_admin",                  "module": "BarkparkWeb.PluginSettingsController",  "action": "update",             "auth": "admin",                 "test_coverage": "yes"},
    {"method": "DELETE", "path": "/v1/plugins/settings/:plugin_name",              "pipeline": "api+require_admin",                  "module": "BarkparkWeb.PluginSettingsController",  "action": "delete",             "auth": "admin",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/plugins/onixedit/export/:dataset/:id",      "pipeline": "api+require_admin",                  "module": "BarkparkWeb.OnixeditExportController",  "action": "show",               "auth": "admin",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/webhooks/:dataset",                          "pipeline": "api+require_admin",                  "module": "BarkparkWeb.WebhookController",         "action": "index",              "auth": "admin",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/v1/webhooks/:dataset/:id",                      "pipeline": "api+require_admin",                  "module": "BarkparkWeb.WebhookController",         "action": "show",               "auth": "admin",                 "test_coverage": "yes"},
    {"method": "POST",   "path": "/v1/webhooks/:dataset",                          "pipeline": "api+require_admin",                  "module": "BarkparkWeb.WebhookController",         "action": "create",             "auth": "admin",                 "test_coverage": "yes"},
    {"method": "PUT",    "path": "/v1/webhooks/:dataset/:id",                      "pipeline": "api+require_admin",                  "module": "BarkparkWeb.WebhookController",         "action": "update",             "auth": "admin",                 "test_coverage": "yes"},
    {"method": "DELETE", "path": "/v1/webhooks/:dataset/:id",                      "pipeline": "api+require_admin",                  "module": "BarkparkWeb.WebhookController",         "action": "delete",             "auth": "admin",                 "test_coverage": "yes"},
    {"method": "GET",    "path": "/media",                                         "pipeline": "api",                                "module": "BarkparkWeb.MediaController",           "action": "index",              "auth": "optional",              "test_coverage": "no"},
    {"method": "GET",    "path": "/media/:id/meta",                                "pipeline": "api",                                "module": "BarkparkWeb.MediaController",           "action": "show",               "auth": "optional",              "test_coverage": "no"},
    {"method": "GET",    "path": "/media/files/*path",                             "pipeline": "api",                                "module": "BarkparkWeb.MediaController",           "action": "serve",              "auth": "optional",              "test_coverage": "no"},
    {"method": "POST",   "path": "/media/upload",                                  "pipeline": "api+require_token",                  "module": "BarkparkWeb.MediaController",           "action": "upload",             "auth": "token",                 "test_coverage": "no"},
    {"method": "DELETE", "path": "/media/:id",                                     "pipeline": "api+require_token",                  "module": "BarkparkWeb.MediaController",           "action": "delete",             "auth": "token",                 "test_coverage": "no"},
    {"method": "GET",    "path": "/api/documents/:type",                           "pipeline": "api+LegacyDeprecation",              "module": "BarkparkWeb.LegacyController",          "action": "index",              "auth": "optional",              "test_coverage": "no"},
    {"method": "GET",    "path": "/api/documents/:type/:id",                       "pipeline": "api+LegacyDeprecation",              "module": "BarkparkWeb.LegacyController",          "action": "show",               "auth": "optional",              "test_coverage": "no"},
    {"method": "POST",   "path": "/api/documents/:type",                           "pipeline": "api+LegacyDeprecation",              "module": "BarkparkWeb.LegacyController",          "action": "create",             "auth": "optional",              "test_coverage": "no"},
    {"method": "DELETE", "path": "/api/documents/:type/:id",                       "pipeline": "api+LegacyDeprecation",              "module": "BarkparkWeb.LegacyController",          "action": "delete",             "auth": "optional",              "test_coverage": "no"},
    {"method": "GET",    "path": "/api/schemas",                                   "pipeline": "api+LegacyDeprecation",              "module": "BarkparkWeb.LegacyController",          "action": "schemas",            "auth": "optional",              "test_coverage": "partial"}
  ],
  "summary": {
    "total": 52,
    "with_tests": 29,
    "no_tests": 14,
    "partial": 9
  }
}
```
