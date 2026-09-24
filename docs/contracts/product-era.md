<!-- doc-tier: agent | canonical-for: product-era | budget: 1400tok -->
# The product era: what core is, the three shapes, and how work is chosen

From commit 10,000 on, Barkpark's job is to run inside other projects. Plan of record: the papers `/papers/the-product-era-2026-09-23` and `/papers/barkspark-2026-09-23`. Goal map root on the ledger: `task-033529087fc4bcef`.

## Core is Barkpark's lake

Core is to Barkpark what the Content Lake is to Sanity. Studio is attached to core the way Sanity Studio is attached to the Lake.

| In core | Attached, as a plugin or a client |
|---|---|
| Documents, schemas, revisions and history | Studio (LiveView) |
| PortableDoc and block ops with `ifRev` | Papers reader and publish surface |
| Query, search (with Indx) and listen | Tasks, Sheets, Sites, ONIX |
| Media | `bp`, the TUI, the JS SDK |
| One token model: rotation, expiry, named keys | Apps such as Barkdown |
| Scope (workspace, project, dataset) and status | |

The test for anything new: if we deleted it, would an app like Barkdown still work? Yes means attached. No means core.

Core has two doors. The HTTP API serves everything outside the process. The plugin contract serves what runs inside it, including Studio. Studio may use only the plugin contract, and anything Studio can do, the API can do too.

## A plugin passes five tests

1. It owns its slice: schemas, migrations, routes, processes, UI, CLI verbs, assets and tests live in its own folder.
2. It declares itself in one manifest.
3. It talks to core only through the contract. Core never calls a plugin by name.
4. Switching it off leaves no routes, processes, tabs or jobs.
5. First-party plugins and app-local plugins in another repo use the same contract.

`GET /v1/capabilities` stays the name of the manifest endpoint: core plus the enabled plugins.

## Three shapes, one core

| | Cloud | Solo | App |
|---|---|---|---|
| What | Managed Barkparks run by `cloud/` | One self-hosted box | Barkpark compiled into another app |
| Run by | Control plane and `barkpark-agent` | The owner | The app, through `startBarkpark` |
| Updates | Cloud self-update relay | `git pull` or a release | With the app version |

Core never assumes a shape: no hard-coded dataset, no self-update when the host owns updates, no login when local. Shape-specific code lives at the edges. A change is proven in every shape it touches.

"Barkspark" is only the codename for the App work. What ships is compiled Barkpark: `@barkpark/server`, `startBarkpark({ dataDir, plugins })` and `bp build`.

## Born clean

A fresh Barkpark carries no sample data, no shared token, no unused tables or processes, and no legacy. Legacy lives only in the one-time upgrade path that moves known boxes across the clean line.

## How work is chosen

- **Finish before starting.** A new epic opens when an old one closes. An epic ends live in the shape that uses it, with its criteria stamped.
- **The process freeze.** No new gate, census task, charter or watcher workflow lands without a named incident it answers. Name the incident in the PR.
- **Security first.** A security P0 is worked the day it is filed.
- **File under the goal map.** New product-era work goes under one of the root goal's branches.
