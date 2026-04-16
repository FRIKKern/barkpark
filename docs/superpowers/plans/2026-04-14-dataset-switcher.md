# Dataset Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote dataset from a hardcoded `@dataset "production"` module attribute to a URL-driven, observed value, so Barkpark Studio can serve multiple datasets (`production`, `staging`, `sdktest`, …) with a topbar switcher — the single biggest feature gap between today's Studio and Sanity.

**Architecture:** Dataset becomes a URL path segment (`/studio/:dataset/...`) and is read from `params` by every Studio LiveView's `mount/3` / `handle_params/3`, then assigned to `socket.assigns.dataset`. A shared `Content.list_datasets/0` powers a `<select>` dataset switcher in the app layout that navigates to `/studio/:new_dataset[/:subpath]` preserving the current section. Every call site in the four Studio LiveViews + the API Tester that currently reads `@dataset` becomes `socket.assigns.dataset` (or for the tester: a per-request value threaded from the LiveView into `TestCases.all(dataset)`). Defaults: `/studio` redirects to `/studio/production`.

**Tech Stack:** Elixir 1.18, Phoenix 1.8 / LiveView 1.0, Ecto/Postgres, ExUnit. No new deps.

**Scope note:** This plan covers the Studio LiveView layer, the API Tester's dataset parameterization, the nav/layout switcher component, and a data-layer `list_datasets/0`. It does **not** touch the `/v1` HTTP API (which already takes `:dataset` as a path param) or the Go TUI. Hardcoded `"production"` strings in `priv/repo/seeds.exs` and legacy controllers stay as-is — they're intentional defaults for dev bootstrap, not Studio-facing.

**Golden rule:** After every code change that touches a Studio LiveView, `MIX_ENV=test mix test` must still pass. The `api/test/` suite is the regression safety net.

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `api/lib/barkpark_web/studio/dataset_switcher.ex` | Function component that renders the `<select>` switcher. One place to style it. |

### Modified files

| File | Change |
|---|---|
| `api/lib/barkpark/content.ex` | Add `list_datasets/0` returning sorted distinct datasets from `schema_definitions` ∪ `documents`, with `"production"` injected as a fallback so a fresh DB still has something to show. |
| `api/lib/barkpark_web/router.ex` | Replace `/studio/*` routes with `/studio/:dataset/*`, add `get "/studio", ... :redirect_to_production` fallback. |
| `api/lib/barkpark_web/controllers/page_controller.ex` | Add `redirect_to_production/2` action. |
| `api/lib/barkpark_web/studio/nav.ex` | `tabs/0` → `tabs/1` — takes `dataset`, returns dataset-prefixed paths. |
| `api/lib/barkpark_web/layouts/app.html.heex` | Render the dataset switcher next to the brand; pass `@dataset` to `Nav.tabs/1`. |
| `api/lib/barkpark_web/live/studio/studio_live.ex` | Remove `@dataset` module attribute; read from `params`; replace all ~60 `@dataset` references with `socket.assigns.dataset`; subscribe to the per-dataset PubSub topic in `mount/3` based on params. |
| `api/lib/barkpark_web/live/studio/dashboard_live.ex` | Same pattern. |
| `api/lib/barkpark_web/live/studio/document_list_live.ex` | Same pattern. |
| `api/lib/barkpark_web/live/studio/document_edit_live.ex` | Same pattern. |
| `api/lib/barkpark_web/live/studio/media_live.ex` | Same pattern; also fix the current bug where it calls `Media.list_files()` without a dataset. |
| `api/lib/barkpark_web/live/studio/api_tester_live.ex` | Assign `dataset` from params; pass to `TestCases.all/1`. |
| `api/lib/barkpark/api_tester/test_cases.ex` | `all/0` → `all/1` — takes dataset, builds all `/v1/data/query/:dataset/...` URLs dynamically. |
| `api/lib/barkpark/media.ex` | Change `list_files/2` default from `"production"` to *required* (kill the silent default) once call sites are fixed. |

### Files touched but behavior unchanged
`content/envelope.ex`, `content/errors.ex`, `api_tester/runner.ex`, `barkpark_web.ex` — **do not edit**. Dataset is already a per-call parameter in the Content context.

---

## Phase 1 — Data layer

### Task 1: `Content.list_datasets/0`

**Files:**
- Modify: `api/lib/barkpark/content.ex` (add function)
- Test: `api/test/barkpark/content_datasets_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Barkpark.ContentDatasetsTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  test "list_datasets returns sorted distinct values from schema_definitions and documents" do
    # Seed two distinct datasets
    {:ok, _} = Content.upsert_schema(%{"name" => "post", "title" => "P", "visibility" => "public", "fields" => []}, "alpha")
    {:ok, _} = Content.upsert_schema(%{"name" => "post", "title" => "P", "visibility" => "public", "fields" => []}, "beta")
    {:ok, _} = Content.create_document("post", %{"_id" => "d1", "title" => "x"}, "gamma")

    datasets = Content.list_datasets()
    assert "alpha" in datasets
    assert "beta" in datasets
    assert "gamma" in datasets
    assert datasets == Enum.sort(datasets)
  end

  test "list_datasets always includes production even on an empty dataset table" do
    datasets = Content.list_datasets()
    assert "production" in datasets
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd api && MIX_ENV=test mix test test/barkpark/content_datasets_test.exs
```
Expected: FAIL with `Content.list_datasets/0 is undefined`

- [ ] **Step 3: Implement `list_datasets/0`**

In `api/lib/barkpark/content.ex`, add below the existing schema-related functions (search for `def list_schemas(dataset)` and add after the `get_schema` group):

```elixir
@doc """
Return all datasets known to the system, sorted alphabetically.
Always includes `"production"` so a brand-new DB still has something to show.
"""
def list_datasets do
  from_schemas =
    from(s in SchemaDefinition, select: s.dataset, distinct: true)
    |> Repo.all()

  from_docs =
    from(d in Document, select: d.dataset, distinct: true)
    |> Repo.all()

  (from_schemas ++ from_docs ++ ["production"])
  |> Enum.uniq()
  |> Enum.sort()
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd api && MIX_ENV=test mix test test/barkpark/content_datasets_test.exs
```
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/content.ex api/test/barkpark/content_datasets_test.exs
git commit -m "feat(content): list_datasets/0 for Studio dataset switcher"
```

---

## Phase 2 — Routing + layout

### Task 2: Dataset-scoped Studio routes + `/studio` redirect

**Files:**
- Modify: `api/lib/barkpark_web/router.ex` (Studio scope)
- Modify: `api/lib/barkpark_web/controllers/page_controller.ex`
- Test: `api/test/barkpark_web/controllers/page_controller_test.exs` (may not exist — create if missing)

- [ ] **Step 1: Write the failing redirect test**

Create `api/test/barkpark_web/controllers/page_controller_test.exs` (or append if it exists):

```elixir
defmodule BarkparkWeb.PageControllerTest do
  use BarkparkWeb.ConnCase, async: true

  test "GET /studio redirects to /studio/production", %{conn: conn} do
    conn = get(conn, "/studio")
    assert redirected_to(conn, 302) == "/studio/production"
  end

  test "GET / redirects to /studio/production", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn, 302) == "/studio/production"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/controllers/page_controller_test.exs
```
Expected: FAIL — current `/studio` routes to `StudioLive` via `live "/"`.

- [ ] **Step 3: Rewrite the Studio router scope**

Replace the existing Studio scope in `api/lib/barkpark_web/router.ex`:

```elixir
  # ── Studio (LiveView) ─────────────────────────────────────────────────────
  # Bare /studio redirects to the default dataset.
  scope "/", BarkparkWeb do
    pipe_through :browser
    get "/", PageController, :redirect_to_studio
    get "/studio", PageController, :redirect_to_studio
  end

  scope "/studio/:dataset", BarkparkWeb.Studio do
    pipe_through :browser

    live "/", StudioLive
    live "/media", MediaLive
    live "/api-tester", ApiTesterLive
    live "/*path", StudioLive
  end
```

Remove the old top-level `/` redirect and the old Studio scope. Preserve any non-Studio routes (`/v1/...`, `/api/...`, `/media/files/...`) — do not touch them.

- [ ] **Step 4: Add the redirect controller action**

In `api/lib/barkpark_web/controllers/page_controller.ex`, add:

```elixir
def redirect_to_studio(conn, _params) do
  redirect(conn, to: "/studio/production")
end
```

Keep the existing `home/2` action if present — it's being replaced by the new `redirect_to_studio/2`, so delete it if nothing else references it.

- [ ] **Step 5: Run test to verify it passes**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/controllers/page_controller_test.exs
```
Expected: `2 tests, 0 failures`

- [ ] **Step 6: Full suite sanity check**

```bash
cd api && MIX_ENV=test mix test
```
Expected: all tests still green. If Studio LiveView tests break because routes changed, note the failure set and continue — the per-LiveView tasks below will fix them. If any non-Studio test breaks, STOP and investigate — that means the router rewrite clobbered something unrelated.

- [ ] **Step 7: Commit**

```bash
git add api/lib/barkpark_web/router.ex api/lib/barkpark_web/controllers/page_controller.ex api/test/barkpark_web/controllers/page_controller_test.exs
git commit -m "feat(router): scope Studio routes under /:dataset + redirect /studio"
```

---

### Task 3: `Nav.tabs/1` takes dataset

**Files:**
- Modify: `api/lib/barkpark_web/studio/nav.ex`
- Test: `api/test/barkpark_web/studio/nav_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule BarkparkWeb.Studio.NavTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.Nav

  test "tabs/1 returns dataset-prefixed paths" do
    [structure, media, api] = Nav.tabs("staging")
    assert structure.id == :structure
    assert structure.path == "/studio/staging"
    assert media.path == "/studio/staging/media"
    assert api.path == "/studio/staging/api-tester"
  end

  test "tabs/1 URL-encodes dataset with special chars" do
    [structure | _] = Nav.tabs("foo bar")
    assert structure.path == "/studio/foo%20bar"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/studio/nav_test.exs
```
Expected: FAIL — `tabs/1 is undefined` (current arity is 0).

- [ ] **Step 3: Rewrite `Nav` with `tabs/1`**

Replace `api/lib/barkpark_web/studio/nav.ex`:

```elixir
defmodule BarkparkWeb.Studio.Nav do
  @moduledoc """
  Single source of truth for Studio top-level navigation tabs.

  Tabs are dataset-aware: `tabs/1` takes the current dataset and returns
  a list of `{id, label, path}` maps with dataset-prefixed paths.
  """

  @type tab :: %{id: atom(), label: String.t(), path: String.t()}

  @spec tabs(String.t()) :: [tab()]
  def tabs(dataset) when is_binary(dataset) do
    ds = URI.encode(dataset)

    [
      %{id: :structure, label: "Structure", path: "/studio/#{ds}"},
      %{id: :media, label: "Media", path: "/studio/#{ds}/media"},
      %{id: :api_tester, label: "API", path: "/studio/#{ds}/api-tester"}
    ]
  end

  @doc "Fallback nav section when a LiveView hasn't set one."
  @spec default() :: atom()
  def default, do: :structure
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/studio/nav_test.exs
```
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark_web/studio/nav.ex api/test/barkpark_web/studio/nav_test.exs
git commit -m "refactor(nav): Nav.tabs/1 takes dataset and emits scoped paths"
```

---

### Task 4: Dataset switcher component + layout wiring

**Files:**
- Create: `api/lib/barkpark_web/studio/dataset_switcher.ex`
- Modify: `api/lib/barkpark_web/layouts/app.html.heex`

- [ ] **Step 1: Create the function component**

```elixir
defmodule BarkparkWeb.Studio.DatasetSwitcher do
  @moduledoc """
  Function component: renders a <select> of known datasets that navigates
  to `/studio/:new_dataset[/:subpath]` on change, preserving the current
  section (structure / media / api-tester).
  """

  use Phoenix.Component

  alias Barkpark.Content

  attr :current, :string, required: true
  attr :current_section, :atom, default: :structure

  def switcher(assigns) do
    datasets = Content.list_datasets()
    assigns = assign(assigns, :datasets, datasets)

    ~H"""
    <label class="dataset-switcher">
      <span class="dataset-switcher-label">Dataset</span>
      <select
        class="dataset-switcher-select"
        onchange={"window.location = '/studio/' + encodeURIComponent(this.value) + #{section_suffix(@current_section)}"}
      >
        <%= for ds <- @datasets do %>
          <option value={ds} selected={ds == @current}><%= ds %></option>
        <% end %>
      </select>
    </label>
    <style>
      .dataset-switcher { display: inline-flex; align-items: center; gap: 8px; margin-left: 12px; font-size: 12px; }
      .dataset-switcher-label { color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; font-size: 10px; }
      .dataset-switcher-select { background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 4px 8px; font-size: 12px; font-family: inherit; cursor: pointer; }
      .dataset-switcher-select:hover { border-color: var(--fg-muted); }
    </style>
    """
  end

  defp section_suffix(:structure), do: "''"
  defp section_suffix(:media), do: "'/media'"
  defp section_suffix(:api_tester), do: "'/api-tester'"
  defp section_suffix(_), do: "''"
end
```

- [ ] **Step 2: Update `app.html.heex` to render switcher and dataset-aware tabs**

Replace `api/lib/barkpark_web/layouts/app.html.heex`:

```heex
<div class="studio-shell">
  <div class="studio-bar">
    <div class="studio-bar-brand">
      <div class="sidebar-brand-icon">B</div>
      <span style="font-weight: 700; font-size: 15px;">Barkpark</span>
      <%= if assigns[:dataset] do %>
        <BarkparkWeb.Studio.DatasetSwitcher.switcher
          current={@dataset}
          current_section={assigns[:nav_section] || :structure}
        />
      <% end %>
    </div>
    <div class="studio-bar-tabs">
      <%= if assigns[:dataset] do %>
        <%= for tab <- BarkparkWeb.Studio.Nav.tabs(@dataset) do %>
          <a
            href={tab.path}
            class={"studio-tab #{if assigns[:nav_section] == tab.id, do: "active"}"}
          ><%= tab.label %></a>
        <% end %>
      <% end %>
    </div>
  </div>

  <%= if Phoenix.Flash.get(@flash, :info) do %>
    <div class="flash flash-info" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :info) %></div>
  <% end %>
  <%= if Phoenix.Flash.get(@flash, :error) do %>
    <div class="flash flash-error" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :error) %></div>
  <% end %>

  {@inner_content}
</div>
```

Key changes:
- Switcher renders only when `@dataset` is present (non-LiveView pages like error pages don't crash)
- `Nav.tabs/1` receives `@dataset`
- Still relies on `@nav_section` for active-tab marking

- [ ] **Step 3: Compile to catch obvious issues**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|warning" | head -10
```
Expected: clean compile. Known-good warnings (`presence` etc.) are fine.

- [ ] **Step 4: Commit**

```bash
git add api/lib/barkpark_web/studio/dataset_switcher.ex api/lib/barkpark_web/layouts/app.html.heex
git commit -m "feat(studio): DatasetSwitcher function component in topbar"
```

---

## Phase 3 — LiveView migration (dataset from params)

Each of the next five tasks follows the **same pattern**:

1. Drop `@dataset "production"` module attribute.
2. In `mount/3`, read `dataset = params["dataset"] || "production"`; `assign(:dataset, dataset)`.
3. Replace every occurrence of `@dataset` with `socket.assigns.dataset`.
4. For PubSub subscriptions tied to dataset, move them into `handle_params/3` (or gate on `connected?(socket)` within mount) so a mid-session dataset switch resubscribes correctly.
5. Keep the `:nav_section` assign added in the previous commit.

**Because these are mechanical replacements, each task is one commit per file.** The shared pattern is spelled out in Task 6 with full code; Tasks 7–10 reference it but are self-contained to avoid reading tasks out of order.

### Task 6: `StudioLive` — dataset from params

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/studio_live.ex`

- [ ] **Step 1: Remove `@dataset` module attribute**

Delete the line `@dataset "production"` near the top of the module (currently line 11).

- [ ] **Step 2: Update `mount/3` to NOT subscribe yet**

Move the PubSub subscription out of `mount/3` into `handle_params/3`. Change the `if connected?(socket) do` block in `mount/3` to only set up presence/user identity:

```elixir
def mount(_params, _session, socket) do
  connect_params = get_connect_params(socket) || %{}
  user_id = connect_params["user_id"] || generate_user_id()
  stored_name = connect_params["user_name"]
  stored_color = connect_params["user_color"]

  user_name = if stored_name && stored_name != "", do: stored_name, else: "User #{String.slice(user_id, 0..3)}"
  user_color = if stored_color && stored_color != "", do: stored_color, else: pick_color(user_id)

  if connected?(socket) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, @presence_topic)
  end

  {:ok, socket
   |> assign(
     nav_section: :structure,
     page_title: "Studio", subscribed_doc: nil,
     image_picker_field: nil, media_files: [],
     ref_picker_field: nil, ref_candidates: [], ref_search: "",
     show_history: false, revisions: [],
     show_delete: false, delete_refs: [],
     user_id: user_id, user_name: user_name, user_color: user_color,
     presences: [], show_profile: false, validation_errors: %{})
   |> allow_upload(:image, accept: ~w(.jpg .jpeg .png .gif .webp .svg), max_entries: 1, max_file_size: 10_000_000)}
end
```

- [ ] **Step 3: Subscribe in `handle_params/3`**

Replace the existing `handle_params/3` with:

```elixir
def handle_params(params, _uri, socket) do
  dataset = params["dataset"] || "production"
  path = Map.get(params, "path", [])

  if connected?(socket) and socket.assigns[:dataset] != dataset do
    if old = socket.assigns[:dataset] do
      Phoenix.PubSub.unsubscribe(Barkpark.PubSub, "documents:#{old}")
    end
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
  end

  socket =
    socket
    |> assign(dataset: dataset, nav_path: path)
    |> rebuild_panes()
    |> subscribe_to_doc()
    |> track_presence()

  {:noreply, socket}
end
```

- [ ] **Step 4: Replace every `@dataset` reference with `socket.assigns.dataset`**

Run this in a shell from the repo root to find every remaining reference:

```bash
grep -n "@dataset" api/lib/barkpark_web/live/studio/studio_live.ex
```

For each match, swap the code to read `socket.assigns.dataset`. Important nuances:

- Inside `handle_event/3` bodies, it's already `socket.assigns.dataset`. ✅
- Inside private helpers (e.g. `rebuild_panes/1`, `resolve_refs/2`) that currently use `@dataset`, add `dataset` as an explicit parameter OR read `socket.assigns.dataset` from the socket passed in.
- The `topic = "doc:#{@dataset}:#{type}:..."` line in `subscribe_to_doc/1` should become `topic = "doc:#{socket.assigns.dataset}:#{type}:..."`.
- `Media.list_files(@dataset, mime_type: "image/")` becomes `Media.list_files(socket.assigns.dataset, mime_type: "image/")`.

After the edits, verify zero `@dataset` remain:

```bash
grep -c "@dataset" api/lib/barkpark_web/live/studio/studio_live.ex
```
Expected: `0`

- [ ] **Step 5: Compile + full suite**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "^\*\*|error|undefined" | head -10
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: clean compile; test suite still green.

- [ ] **Step 6: Manual smoke test**

Start the server and hit the two URL shapes that matter:

```bash
cd api && MIX_ENV=dev mix phx.server &
sleep 5
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio/production
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio/sdktest
kill %1
```
Expected: `302` for `/studio`, `200` for `/studio/production`, `200` for `/studio/sdktest`.

- [ ] **Step 7: Commit**

```bash
git add api/lib/barkpark_web/live/studio/studio_live.ex
git commit -m "refactor(studio): StudioLive reads dataset from URL params"
```

---

### Task 7: `DashboardLive` — dataset from params

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/dashboard_live.ex`

- [ ] **Step 1: Delete the module attribute**

Remove `@dataset "production"` (line ~6).

- [ ] **Step 2: Read dataset in `mount/3`**

Replace the existing `mount/3` with:

```elixir
def mount(params, _session, socket) do
  dataset = params["dataset"] || "production"

  if connected?(socket) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
  end

  structure = Structure.build(dataset)

  {:ok,
   assign(socket,
     nav_section: :structure,
     dataset: dataset,
     structure: structure,
     counts: count_all(structure, dataset)
   )}
end
```

Adapt the assigns to match what `DashboardLive` already uses (peek at the current mount to preserve names — do NOT invent new assigns).

- [ ] **Step 3: Replace all `@dataset` references**

```bash
grep -n "@dataset" api/lib/barkpark_web/live/studio/dashboard_live.ex
```

Each match becomes `socket.assigns.dataset` inside `handle_event`/`handle_info`, or a local `dataset` variable passed explicitly into private helpers.

The `count_all/2` helper should take `dataset` as an argument:

```elixir
defp count_all(structure, dataset) do
  for node <- structure.nodes, into: %{} do
    count = length(Content.list_documents(node.type_name, dataset, perspective: :drafts))
    {node.type_name, count}
  end
end
```

Verify:

```bash
grep -c "@dataset" api/lib/barkpark_web/live/studio/dashboard_live.ex
```
Expected: `0`

- [ ] **Step 4: Compile + test**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark_web/live/studio/dashboard_live.ex
git commit -m "refactor(studio): DashboardLive reads dataset from URL params"
```

---

### Task 8: `DocumentListLive` — dataset from params

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/document_list_live.ex`

- [ ] **Step 1: Delete `@dataset "production"`**

- [ ] **Step 2: Update `mount/3` to read from params**

```elixir
def mount(%{"type" => type, "dataset" => dataset} = params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
  end

  schema = case Content.get_schema(type, dataset) do
    {:ok, s} -> s
    _ -> nil
  end

  type_node = Structure.type_node(type, dataset)
  # ...rest unchanged, replacing @dataset with the local `dataset`
```

Preserve the rest of the current `mount/3` body; only swap the parameter source and `@dataset` references.

- [ ] **Step 3: Replace `@dataset` in all handlers**

`handle_event("create_doc", ...)`, `handle_event("delete_doc", ...)`, `handle_params/3`, etc. Each reads `socket.assigns.dataset` (set in mount).

```bash
grep -c "@dataset" api/lib/barkpark_web/live/studio/document_list_live.ex
```
Expected: `0`

- [ ] **Step 4: Compile + test**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark_web/live/studio/document_list_live.ex
git commit -m "refactor(studio): DocumentListLive reads dataset from URL params"
```

---

### Task 9: `DocumentEditLive` — dataset from params

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/document_edit_live.ex`

- [ ] **Step 1: Delete `@dataset`**

- [ ] **Step 2: Update `mount/3`**

```elixir
def mount(%{"type" => type, "id" => id, "dataset" => dataset}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
  end

  schema = case Content.get_schema(type, dataset) do
    {:ok, s} -> s
    _ -> nil
  end

  {:ok, socket |> assign(nav_section: :structure, dataset: dataset, type: type, doc_id: id, schema: schema) |> load_doc()}
end
```

Adapt `load_doc/1` and similar helpers to read `socket.assigns.dataset`.

- [ ] **Step 3: Replace `@dataset` references**

Every `Content.*(..., @dataset)` call becomes `Content.*(..., socket.assigns.dataset)`. The `publish_document` / `unpublish_document` / `discard_draft` / `get_document` helpers all take dataset as the last arg — verify.

```bash
grep -c "@dataset" api/lib/barkpark_web/live/studio/document_edit_live.ex
```
Expected: `0`

- [ ] **Step 4: Compile + test**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark_web/live/studio/document_edit_live.ex
git commit -m "refactor(studio): DocumentEditLive reads dataset from URL params"
```

---

### Task 10: `MediaLive` — dataset from params + fix silent default

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/media_live.ex`
- Modify: `api/lib/barkpark/media.ex` (drop the default)

- [ ] **Step 1: Update `MediaLive.mount/3`**

```elixir
def mount(%{"dataset" => dataset}, _session, socket) do
  files = Media.list_files(dataset)

  socket =
    socket
    |> assign(nav_section: :media, dataset: dataset, files: files, page_title: "Media Library", selected_file: nil)
    |> allow_upload(:media, accept: :any, max_entries: 5, max_file_size: 100_000_000)

  {:ok, socket}
end
```

- [ ] **Step 2: Update every `Media.list_files`/`Media.upload` call in MediaLive to pass `socket.assigns.dataset`**

```bash
grep -n "Media\." api/lib/barkpark_web/live/studio/media_live.ex
```

Each call passes dataset explicitly.

- [ ] **Step 3: Remove the silent `"production"` default in `Media.list_files`**

In `api/lib/barkpark/media.ex`:

```elixir
# Before:
def list_files(dataset \\ "production", opts \\ []) do
# After:
def list_files(dataset, opts \\ []) when is_binary(dataset) do
```

- [ ] **Step 4: Find and fix any other callers of `Media.list_files/0`**

```bash
grep -rn "Media.list_files()" api/lib api/test
```

Any call with no arguments must be updated to pass a dataset. If a test calls it, update the test to pass `"test"`.

- [ ] **Step 5: Compile + test**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark_web/live/studio/media_live.ex api/lib/barkpark/media.ex
git commit -m "refactor(studio): MediaLive reads dataset from URL params; kill silent default"
```

---

### Task 11: `ApiTesterLive` + dataset-aware `TestCases`

**Files:**
- Modify: `api/lib/barkpark/api_tester/test_cases.ex`
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`
- Test: `api/test/barkpark/api_tester/test_cases_test.exs`

- [ ] **Step 1: Failing test for `TestCases.all/1`**

```elixir
defmodule Barkpark.ApiTester.TestCasesTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.TestCases

  test "all/1 builds URLs for the given dataset" do
    cases = TestCases.all("staging")
    envelope = Enum.find(cases, &(&1.id == "query-flat-envelope"))
    assert envelope.path == "/v1/data/query/staging/post?limit=1"

    schemas = Enum.find(cases, &(&1.id == "schemas-list"))
    assert schemas.path == "/v1/schemas/staging"
  end

  test "find/2 returns a case by id for a given dataset" do
    tc = TestCases.find("staging", "query-flat-envelope")
    assert tc.path == "/v1/data/query/staging/post?limit=1"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/test_cases_test.exs
```
Expected: FAIL — `all/1` is undefined (current arity is 0).

- [ ] **Step 3: Rewrite `TestCases` to take dataset**

Replace `api/lib/barkpark/api_tester/test_cases.ex` (keeping the existing cases; only parameterizing dataset):

```elixir
defmodule Barkpark.ApiTester.TestCases do
  @moduledoc """
  Canonical v1 HTTP contract test cases for the in-browser API Tester pane.

  All paths are built from the `dataset` argument, so the same battery
  runs against `production`, `staging`, `sdktest`, or whatever the user
  has selected in the Studio topbar.
  """

  @token "barkpark-dev-token"
  @auth {"Authorization", "Bearer " <> @token}

  @spec all(String.t()) :: [map()]
  def all(dataset) when is_binary(dataset) do
    ds = URI.encode(dataset)

    [
      %{
        id: "query-flat-envelope",
        category: "Query",
        label: "Envelope shape",
        description: "Public read — confirms reserved _-keys and flat field layout",
        method: "GET",
        path: "/v1/data/query/#{ds}/post?limit=1",
        headers: [],
        body: nil,
        expect: {200, :envelope_has_reserved_keys}
      },
      %{
        id: "query-pagination",
        category: "Query",
        label: "Pagination (limit+offset)",
        description: "Second page is disjoint from the first",
        method: "GET",
        path: "/v1/data/query/#{ds}/post?limit=2&offset=2",
        headers: [],
        body: nil,
        expect: {200, :ok}
      },
      %{
        id: "query-order-asc",
        category: "Query",
        label: "Order _createdAt:asc",
        description: "Chronological order, oldest first",
        method: "GET",
        path: "/v1/data/query/#{ds}/post?order=_createdAt:asc&limit=5",
        headers: [],
        body: nil,
        expect: {200, :order_ascending}
      },
      %{
        id: "query-filter",
        category: "Query",
        label: "Filter by title",
        description: "Exact-match filter on a top-level field",
        method: "GET",
        path: "/v1/data/query/#{ds}/post?filter%5Btitle%5D=prod%20smoke%20v1%20patched",
        headers: [],
        body: nil,
        expect: {200, :ok}
      },
      %{
        id: "doc-missing-404",
        category: "Query",
        label: "404 on missing doc (structured error)",
        description: "Expected: {error: {code: 'not_found', message: ...}}",
        method: "GET",
        path: "/v1/data/doc/#{ds}/post/does-not-exist-xyz",
        headers: [],
        body: nil,
        expect: {404, :error_code_not_found}
      },
      %{
        id: "schemas-no-auth",
        category: "Schemas",
        label: "Schemas without auth → 401 structured",
        description: "Confirms the auth plug emits the v1 envelope",
        method: "GET",
        path: "/v1/schemas/#{ds}",
        headers: [],
        body: nil,
        expect: {401, :error_code_unauthorized}
      },
      %{
        id: "schemas-list",
        category: "Schemas",
        label: "/v1/schemas/:dataset",
        description: "Admin list — _schemaVersion: 1 + schemas array",
        method: "GET",
        path: "/v1/schemas/#{ds}",
        headers: [@auth],
        body: nil,
        expect: {200, :schema_version_1}
      },
      %{
        id: "mutate-malformed",
        category: "Mutations",
        label: "Malformed body → 400",
        description: "Missing `mutations` key surfaces the malformed error",
        method: "POST",
        path: "/v1/data/mutate/#{ds}",
        headers: [@auth, {"Content-Type", "application/json"}],
        body: %{"not_mutations" => []},
        expect: {400, :error_code_malformed}
      },
      %{
        id: "mutate-create",
        category: "Mutations",
        label: "createOrReplace returns envelope",
        description: "Round-trips through Envelope.render — verify _rev is 32 hex chars",
        method: "POST",
        path: "/v1/data/mutate/#{ds}",
        headers: [@auth, {"Content-Type", "application/json"}],
        body: %{
          "mutations" => [
            %{
              "createOrReplace" => %{
                "_id" => "tester-1",
                "_type" => "post",
                "title" => "Tester created this",
                "body" => "hello from the tester pane"
              }
            }
          ]
        },
        expect: {200, :mutate_result_has_envelope}
      },
      %{
        id: "mutate-atomic-rollback",
        category: "Mutations",
        label: "Atomic rollback on partial failure",
        description: "create+publish where publish fails → create rolls back",
        method: "POST",
        path: "/v1/data/mutate/#{ds}",
        headers: [@auth, {"Content-Type", "application/json"}],
        body: %{
          "mutations" => [
            %{
              "create" => %{
                "_id" => "tester-rollback",
                "_type" => "post",
                "title" => "should not persist"
              }
            },
            %{"publish" => %{"id" => "tester-nonexistent", "type" => "post"}}
          ]
        },
        expect: {404, :error_code_not_found}
      },
      %{
        id: "mutate-conflict",
        category: "Mutations",
        label: "Duplicate create → 409 conflict",
        description: "Run twice back-to-back — the second call conflicts",
        method: "POST",
        path: "/v1/data/mutate/#{ds}",
        headers: [@auth, {"Content-Type", "application/json"}],
        body: %{
          "mutations" => [
            %{
              "create" => %{
                "_id" => "tester-conflict",
                "_type" => "post",
                "title" => "first"
              }
            }
          ]
        },
        expect: {200, :ok}
      },
      %{
        id: "mutate-no-auth",
        category: "Auth",
        label: "Mutate without token → 401 structured",
        description: "Verifies RequireToken plug emits v1 error envelope",
        method: "POST",
        path: "/v1/data/mutate/#{ds}",
        headers: [{"Content-Type", "application/json"}],
        body: %{"mutations" => []},
        expect: {401, :error_code_unauthorized}
      },
      %{
        id: "legacy-deprecation",
        category: "Legacy",
        label: "/api/schemas carries Deprecation headers",
        description: "Response body is legacy shape; headers announce sunset",
        method: "GET",
        path: "/api/schemas",
        headers: [],
        body: nil,
        expect: {200, :legacy_deprecation_headers}
      }
    ]
  end

  @spec find(String.t(), String.t()) :: map() | nil
  def find(dataset, id), do: Enum.find(all(dataset), &(&1.id == id))
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd api && MIX_ENV=test mix test test/barkpark/api_tester/test_cases_test.exs
```
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Update `ApiTesterLive` to use the dataset from params**

In `api/lib/barkpark_web/live/studio/api_tester_live.ex`, rewrite `mount/3`:

```elixir
def mount(%{"dataset" => dataset}, _session, socket) do
  cases = TestCases.all(dataset)

  {:ok,
   assign(socket,
     nav_section: :api_tester,
     dataset: dataset,
     cases: cases,
     categories: cases |> Enum.map(& &1.category) |> Enum.uniq(),
     selected_id: (List.first(cases) || %{id: nil}).id,
     custom_body: "",
     last_result: nil,
     running: false,
     results_by_id: %{}
   )}
end
```

Update every reference to `TestCases.find(id)` in the handlers to `TestCases.find(socket.assigns.dataset, id)`:

```elixir
def handle_event("select", %{"id" => id}, socket) do
  tc = TestCases.find(socket.assigns.dataset, id)
  # ...rest unchanged
end

def handle_event("run", _, socket) do
  tc = TestCases.find(socket.assigns.dataset, socket.assigns.selected_id)
  # ...rest unchanged
end
```

Update `handle_event("run-all", ...)` to not refetch cases — they're already in `socket.assigns.cases`:

```elixir
def handle_event("run-all", _, socket) do
  results =
    socket.assigns.cases
    |> Enum.reduce(%{}, fn tc, acc -> Map.put(acc, tc.id, Runner.run(tc)) end)

  {:noreply, assign(socket, results_by_id: results, last_result: results[socket.assigns.selected_id])}
end
```

Also update `TestCases.find(@selected_id)` usages inside the `render/1` template to pass `@dataset`:

```heex
<%= if tc = TestCases.find(@dataset, @selected_id) do %>
```

- [ ] **Step 6: Compile + full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add api/lib/barkpark/api_tester/test_cases.ex api/lib/barkpark_web/live/studio/api_tester_live.ex api/test/barkpark/api_tester/test_cases_test.exs
git commit -m "refactor(api-tester): TestCases.all/1 + ApiTesterLive reads dataset"
```

---

## Phase 4 — End-to-end verification

### Task 12: Integration smoke + deploy

**Files:**
- None (no code changes)

- [ ] **Step 1: Start dev server**

```bash
cd api && MIX_ENV=dev mix phx.server
```

Leave running in the background.

- [ ] **Step 2: Probe three datasets via HTTP**

```bash
# /studio redirects to /studio/production
curl -sI http://localhost:4000/studio | grep -i "^location"

# /studio/production renders with production in the tab paths
curl -s http://localhost:4000/studio/production | grep -oE 'href="/studio/[^"]+"' | sort -u

# /studio/sdktest renders with sdktest in tab paths
curl -s http://localhost:4000/studio/sdktest | grep -oE 'href="/studio/[^"]+"' | sort -u

# API tester shows production cases
curl -s http://localhost:4000/studio/production/api-tester | grep -oE '/v1/data/query/[^"<]+' | head -3

# API tester shows sdktest cases
curl -s http://localhost:4000/studio/sdktest/api-tester | grep -oE '/v1/data/query/[^"<]+' | head -3
```

Expected outputs:
- Redirect: `location: /studio/production`
- Tabs on `/studio/production` contain `/studio/production`, `/studio/production/media`, `/studio/production/api-tester`
- Tabs on `/studio/sdktest` contain `/studio/sdktest`, `/studio/sdktest/media`, `/studio/sdktest/api-tester`
- API tester cases on `/studio/production/api-tester` include `/v1/data/query/production/post...`
- API tester cases on `/studio/sdktest/api-tester` include `/v1/data/query/sdktest/post...`

- [ ] **Step 3: Run the full Elixir suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: zero failures. Test count should be ≥ 27 + new tests from Tasks 1–4 and 11 (~32–34 total).

- [ ] **Step 4: Stop dev server**

```bash
kill %1
```

- [ ] **Step 5: Deploy to /opt/barkpark**

```bash
cd /opt/barkpark && git pull
```

The post-merge hook will nuke `_build/prod`, recompile, and restart the service. Expected tail of output: `[post-merge] Done. Service restarted.`

- [ ] **Step 6: Verify the deployed instance**

```bash
systemctl is-active barkpark
curl -sI http://89.167.28.206/studio | grep -i "^location"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://89.167.28.206/studio/production
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://89.167.28.206/studio/sdktest
curl -s http://89.167.28.206/studio/production | grep -oE 'class="dataset-switcher-select"' | head -1
```

Expected:
- Service `active`
- Redirect location `/studio/production`
- `HTTP 200` for both dataset URLs
- Switcher class present in rendered HTML

- [ ] **Step 7: Browser sanity check**

Open `http://89.167.28.206/studio` in a browser:
1. Confirm you're redirected to `/studio/production`
2. The topbar shows a Dataset dropdown next to the `B` brand, current value `production`
3. Click the dropdown, select `sdktest` — URL changes to `/studio/sdktest`
4. Click `API` tab — URL becomes `/studio/sdktest/api-tester`
5. Test cases in the API tester show `/v1/data/query/sdktest/post...` URLs
6. Click `Run all` — every test case runs against the `sdktest` dataset

If any of these fail, stop and dispatch a fix — do NOT call the plan complete.

- [ ] **Step 8: Final commit if anything changed during verification**

If step 7 surfaced a bug that needed a quick fix, commit it separately with a descriptive message and re-deploy.

---

## Self-Review

**1. Spec coverage:**

- Dataset as URL segment → Task 2 (router) + Tasks 6–11 (LiveViews read from params) ✓
- `list_datasets/0` data layer → Task 1 ✓
- Dataset switcher component in topbar → Task 4 ✓
- Nav tabs emit dataset-scoped paths → Task 3 ✓
- API Tester runs against current dataset → Task 11 ✓
- `/studio` → `/studio/production` redirect → Task 2 ✓
- `@dataset` module attributes removed from all four LiveViews → Tasks 6–10 ✓
- Silent `Media.list_files/0` default killed → Task 10 ✓
- End-to-end deploy + browser verification → Task 12 ✓

No gaps found.

**2. Placeholder scan:** No TBDs, TODOs, "similar to", or untyped "handle edge cases" phrases. Every step shows the real code or the exact command.

**3. Type consistency:**
- `Nav.tabs/1` called consistently across Task 3 (definition), Task 4 (layout use), Task 6–11 (no calls — layout only) ✓
- `TestCases.all/1` and `TestCases.find/2` signatures consistent between Task 11's test, implementation, and caller ✓
- `Content.list_datasets/0` arity 0 in Task 1 and Task 4 caller ✓
- `Media.list_files/2` arity change in Task 10 consistent with call sites ✓

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-04-14-dataset-switcher.md`.**

**Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task with spec + code quality review between tasks. Best for a 12-task plan like this where Tasks 6–10 are mechanical but lengthy.

**2. Inline Execution** — run in this session with checkpoints at each phase boundary.

Which approach?
