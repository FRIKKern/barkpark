<!-- doc-tier: human | canonical-for: session-handoff-plan | budget: 12000tok -->

# Session Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First-class `session` content type (living document: open → log events → checkpoint → close → resume) with paper-editor support, `bp session` verbs, task-side `sessions[]` references, and the lifecycle + resume skills.

**Architecture:** The Bulldocs plugin gains a `session` schema (blocks body + metadata + append-only `events[]`) and session routes that reuse the paper machinery through a blocks-type whitelist `{paper, session}` — `Content.apply_document_block_op/5` already exists as the generic twin. Tasks get an additive `sessions` arrayOf-reference field and a `/v1/tasks/:id/sessions` endpoint cloned from the `/papers` CAS core. CLI verbs are manifest-only (no Go changes). Skills are prose + `bp` CLI.

**Tech Stack:** Elixir/Phoenix (`api/`), manifest-driven Go CLI (no changes), bash (scrub helper), markdown skills.

**Spec:** `docs/superpowers/specs/2026-07-25-session-handoff-design.md` (mirrored at `/papers/session-handoff-design`). v1.5 auto-log is already filed as `task-bc34e83515bbd91f` — NOT in this plan.

## Global Constraints

- Blocks-type whitelist is exactly `["paper", "session"]` — never an open door.
- Event kinds are exactly `["paper-published", "task-closed", "epic-wave-complete", "push", "note"]`; unknown kind → 422.
- Event `ts` is **server-minted** (`DateTime.utc_now() |> DateTime.to_iso8601()`) — never taken from the caller.
- `events` is append-only; no update/delete surface.
- Session slug convention: `session-YYYY-MM-DD-<topic>`.
- Session ingest allows **metadata-only** payloads (no blocks) — `bp session open` sends no body blocks.
- Existing paper behavior must not move: every generalized function keeps a `"paper"` default and existing tests stay green.
- All work in a git worktree on branch `feat/session-handoff`; the main checkout NEVER leaves `main` (CLAUDE.md Golden Rule 8).
- Tests: `cd api && mix test <path>` per task; full `cd api && mix test` before PR.
- Task-schema invariant: every field map MUST carry `"group"` (regression-tested in `tasks_schema_dossier_test.exs`).
- Commit after each task; Elixir commits prefixed `feat(sessions):` / docs `docs(sessions):`.

---

### Task 1: `session` schema JSON + Bulldocs registration

**Files:**
- Create: `api/priv/plugins/bulldocs/schemas/session.json`
- Modify: `api/lib/barkpark/plugins/bulldocs.ex:141-153` (`register_schemas/1` file list)
- Test: `api/test/barkpark/plugins/bulldocs_session_schema_test.exs`

**Interfaces:**
- Produces: schema `name: "session"` registered in dataset `production`; fields consumed by Tasks 3–5 (`status`, `events`, `transcript`, etc.).

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark/plugins/bulldocs_session_schema_test.exs
defmodule Barkpark.Plugins.BulldocsSessionSchemaTest do
  use ExUnit.Case, async: true

  test "register_schemas includes the session schema" do
    schemas = Barkpark.Plugins.Bulldocs.register_schemas([])
    session = Enum.find(schemas, &(&1.name == "session"))
    assert session, "session schema not registered"
    field_names = Enum.map(session.fields, & &1["name"])

    for f <- ~w(harness session_uuid cwd machine git_head git_branch started_at ended_at transcript status events) do
      assert f in field_names, "missing field #{f}"
    end

    events = Enum.find(session.fields, &(&1["name"] == "events"))
    assert events["type"] == "arrayOf"
    assert events["of"]["type"] == "composite"
    kind = Enum.find(events["of"]["fields"], &(&1["name"] == "kind"))
    assert kind["options"] == ["paper-published", "task-closed", "epic-wave-complete", "push", "note"]

    status = Enum.find(session.fields, &(&1["name"] == "status"))
    assert status["options"] == ["open", "closed", "resumed", "superseded"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark/plugins/bulldocs_session_schema_test.exs`
Expected: FAIL — "session schema not registered"

- [ ] **Step 3: Create the schema JSON**

`api/priv/plugins/bulldocs/schemas/session.json` (mirror `paper.json`'s top-level shape — read it first for `name/title/icon/visibility/fields` keys; field vocabulary per `docs/contracts/schema-v2.md`: `options` for select enums, `of` descriptor for arrayOf, `refType` for references):

```json
{
  "name": "session",
  "title": "Session",
  "icon": "🧵",
  "visibility": "public",
  "fields": [
    {"name": "title", "title": "Title", "type": "string", "group": "meta",
     "description": "Human-readable session title."},
    {"name": "harness", "title": "Harness", "type": "select", "group": "meta",
     "options": ["claude-code", "codex", "other"],
     "description": "Which agent harness produced this session."},
    {"name": "session_uuid", "title": "Session UUID", "type": "string", "group": "meta",
     "description": "Harness-native session id (transcript lookup key)."},
    {"name": "cwd", "title": "Working directory", "type": "string", "group": "meta",
     "description": "Working directory on the origin machine."},
    {"name": "machine", "title": "Machine", "type": "string", "group": "meta",
     "description": "Hostname of the origin machine."},
    {"name": "git_head", "title": "Git HEAD", "type": "string", "group": "meta",
     "description": "Commit SHA at last update."},
    {"name": "git_branch", "title": "Git branch", "type": "string", "group": "meta",
     "description": "Branch at last update."},
    {"name": "started_at", "title": "Started", "type": "datetime", "group": "meta",
     "description": "Session start."},
    {"name": "ended_at", "title": "Ended", "type": "datetime", "group": "meta",
     "description": "Session end (set on close)."},
    {"name": "transcript", "title": "Transcript", "type": "reference", "refType": "mediaAsset",
     "group": "meta",
     "description": "Scrubbed transcript JSONL media asset. Optional — synthesis-only sessions allowed."},
    {"name": "status", "title": "Status", "type": "select", "group": "meta",
     "options": ["open", "closed", "resumed", "superseded"],
     "description": "Lifecycle state. open → closed on final checkpoint; resumed when picked up elsewhere."},
    {"name": "events", "title": "Events", "type": "arrayOf", "ordered": true, "group": "trail",
     "description": "Append-only milestone trail. Server-stamped ts; appended via POST /v1/plugins/bulldocs/sessions/:slug/events.",
     "of": {
       "name": "event",
       "type": "composite",
       "fields": [
         {"name": "ts", "title": "At", "type": "datetime"},
         {"name": "kind", "title": "Kind", "type": "select",
          "options": ["paper-published", "task-closed", "epic-wave-complete", "push", "note"]},
         {"name": "ref", "title": "Ref", "type": "string"},
         {"name": "note", "title": "Note", "type": "text", "rows": 2}
       ]
     }}
  ]
}
```

If `paper.json` declares `groups`, add matching `"groups": [{"name": "meta", ...}, {"name": "trail", ...}]`; if it has no groups key, keep the per-field `"group"` values anyway (harmless) but do not invent a top-level key `paper.json` lacks.

- [ ] **Step 4: Register it** — in `bulldocs.ex:143`, change the file list:

```elixir
for file <- ["paper.json", "form_response.json", "session.json"] do
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd api && mix test test/barkpark/plugins/bulldocs_session_schema_test.exs`
Expected: PASS

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat(sessions): session schema registered by bulldocos plugin"` (fix the typo: `bulldocs`)

---

### Task 2: Content layer — blocks-type whitelist + generalized upsert

**Files:**
- Modify: `api/lib/barkpark/content/papers.ex` (~:45-56, delegations ~:1509)
- Modify: `api/lib/barkpark/content/papers/block_ops.ex` (`upsert_paper` at :70)
- Modify: `api/lib/barkpark/content.ex` (~:670, re-delegations)
- Test: `api/test/barkpark/content/session_blocks_doc_test.exs`

**Interfaces:**
- Produces: `Content.blocks_types/0` → `["paper", "session"]`; `Content.blocks_type?/1`; `Content.upsert_blocks_doc(type, attrs, opts)` → same return as `upsert_paper/2`; `Content.get_blocks_doc(slug, type, dataset, opts)` → `%Document{} | nil`. Consumed by Tasks 3, 4, and pane_builder in Task 3.
- Consumes: session schema from Task 1 (integration test registers it).

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark/content/session_blocks_doc_test.exs
defmodule Barkpark.Content.SessionBlocksDocTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.Content

  test "blocks_types is the closed whitelist" do
    assert Content.blocks_types() == ["paper", "session"]
    assert Content.blocks_type?("session")
    refute Content.blocks_type?("post")
  end

  test "upsert_blocks_doc rejects non-whitelist types" do
    assert {:error, :not_a_blocks_type} =
             Content.upsert_blocks_doc("post", %{"slug" => "nope", "blocks" => []})
  end

  test "upsert_blocks_doc creates a session and get_blocks_doc reads it back" do
    attrs = %{
      "slug" => "session-2026-07-25-test",
      "title" => "Test session",
      "blocks" => [%{"id" => "s1", "type" => "paragraph", "content" => ["hello"]}],
      "status" => "open"
    }

    assert {:ok, _} = Content.upsert_blocks_doc("session", attrs)
    doc = Content.get_blocks_doc("session-2026-07-25-test", "session", "production")
    assert doc
    assert doc.content["status"] == "open"
  end

  test "upsert_blocks_doc session allows metadata-only (no blocks)" do
    attrs = %{"slug" => "session-2026-07-25-meta-only", "title" => "Meta", "status" => "open"}
    assert {:ok, _} = Content.upsert_blocks_doc("session", attrs)
  end

  test "upsert_paper still works unchanged" do
    attrs = %{"slug" => "plain-paper-regression", "title" => "P",
              "blocks" => [%{"id" => "p1", "type" => "paragraph", "content" => ["x"]}]}
    assert {:ok, _} = Content.upsert_paper(attrs)
    assert Content.get_paper("plain-paper-regression")
  end
end
```

Check `Barkpark.DataCase` exists (it's the standard Phoenix data case; if the repo's convention is `Barkpark.DataCase` under a different name, mirror what `test/barkpark/content/` neighbors use). If session upsert requires the schema, call the same `register_schemas!`-style helper the tasks controller test uses in a `setup`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && mix test test/barkpark/content/session_blocks_doc_test.exs`
Expected: FAIL — `blocks_types/0` undefined

- [ ] **Step 3: Implement.** Read `block_ops.ex:60-140` fully first. Then:

In `papers.ex` (next to `@paper_type`):

```elixir
@blocks_types ["paper", "session"]
def blocks_types, do: @blocks_types
def blocks_type?(type), do: type in @blocks_types

def get_blocks_doc(slug, type, dataset \\ @paper_default_dataset, opts \\ [])
    when is_binary(slug) and is_binary(type) do
  case Content.get_document(slug, type, dataset, opts) do
    {:ok, doc} -> doc
    {:error, :not_found} -> nil
  end
end
```

In `block_ops.ex`, generalize `upsert_paper/2` into `upsert_blocks_doc/3`: thread `type` through everywhere the current body hard-codes `"paper"` (the existing-doc lookup, the `upsert_document` write, any template/constraint call — for `type == "session"` skip paper-only template constraints (`Papers.Template.paper_declarations()` stays paper-only) and treat missing `"blocks"` as `[]`). Head:

```elixir
def upsert_blocks_doc(type, attrs, opts \\ [])

def upsert_blocks_doc(type, _attrs, _opts) when type not in ["paper", "session"],
  do: {:error, :not_a_blocks_type}

def upsert_blocks_doc(type, attrs, opts) when is_map(attrs) and is_list(opts) do
  # generalized body of the old upsert_paper, with `type` threaded through
end

def upsert_paper(attrs, opts \\ []), do: upsert_blocks_doc("paper", attrs, opts)
```

Add delegations in `papers.ex` (~:1509 block) and `content.ex` (~:670 block) for `upsert_blocks_doc/3`, `get_blocks_doc/4`, `blocks_types/0`, `blocks_type?/1`.

- [ ] **Step 4: Run the new test AND the existing paper suites**

Run: `cd api && mix test test/barkpark/content/session_blocks_doc_test.exs test/barkpark/content/ test/barkpark_web/controllers/bulldocs_ingest_controller_test.exs`
Expected: ALL PASS (paper regressions green)

- [ ] **Step 5: Commit** — `feat(sessions): blocks-type whitelist + generalized upsert_blocks_doc`

---

### Task 3: Bulldocs session routes, ingest/show/ops actions, paper-pane dispatch

**Files:**
- Modify: `api/lib/barkpark/plugins/bulldocs.ex` (routes at :202-204)
- Modify: `api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex` (ingest :94, apply_op :297/:385)
- Modify: `api/lib/barkpark_web/studio/pane_builder.ex` (:415-418 and :200-206)
- Test: `api/test/barkpark_web/controllers/bulldocs_sessions_controller_test.exs`

**Interfaces:**
- Consumes: `Content.upsert_blocks_doc/3`, `Content.get_blocks_doc/4`, `Content.blocks_type?/1` (Task 2); `Content.apply_document_block_op/5` (exists, `block_ops.ex:838`).
- Produces: `POST /v1/plugins/bulldocs/sessions` (upsert), `GET /v1/plugins/bulldocs/sessions/:slug` (JSON doc), `POST /v1/plugins/bulldocs/sessions/:slug/ops` (block ops). Auth `:ingest` for writes, `:ingest` for GET too (symmetry with the write tier; the doc is also readable via public paper routes once published).

- [ ] **Step 1: Write the failing test** (conventions from `bulldocs_ingest_controller_test.exs`: `use BarkparkWeb.ConnCase, async: false`, `@token "barkpark-test-ingest-token"`):

```elixir
# api/test/barkpark_web/controllers/bulldocs_sessions_controller_test.exs
defmodule BarkparkWeb.BulldocsSessionsControllerTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/sessions"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp body(slug, extra \\ %{}) do
    Map.merge(%{"slug" => slug, "title" => "S", "status" => "open"}, extra)
    |> Jason.encode!()
  end

  test "rejects with no token", %{conn: conn} do
    conn = conn |> put_req_header("content-type", "application/json") |> post(@path, body("s-no-token"))
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "upserts a metadata-only session", %{conn: conn} do
    resp = conn |> authed() |> post(@path, body("session-2026-07-25-a"))
    assert json_response(resp, 200)["ok"] == true
    assert Content.get_blocks_doc("session-2026-07-25-a", "session", "production")
  end

  test "upserts with blocks and reads back via GET", %{conn: conn} do
    blocks = [%{"id" => "b1", "type" => "paragraph", "content" => ["synth"]}]
    resp = conn |> authed() |> post(@path, body("session-2026-07-25-b", %{"blocks" => blocks}))
    assert json_response(resp, 200)["ok"] == true

    show = conn |> authed() |> get(@path <> "/session-2026-07-25-b")
    payload = json_response(show, 200)
    assert payload["slug"] == "session-2026-07-25-b"
    assert payload["status"] == "open"
    assert [%{"type" => "paragraph"} | _] = payload["blocks"]
  end

  test "GET unknown slug is 404", %{conn: conn} do
    resp = conn |> authed() |> get(@path <> "/session-nope")
    assert json_response(resp, 404)
  end

  test "applies a block op to a session", %{conn: conn} do
    conn |> authed() |> post(@path, body("session-2026-07-25-c",
      %{"blocks" => [%{"id" => "b1", "type" => "paragraph", "content" => ["v1"]}]}))

    op = %{"op" => "replace", "block_id" => "b1",
           "block" => %{"id" => "b1", "type" => "paragraph", "content" => ["v2"]}}
    resp = conn |> authed() |> post(@path <> "/session-2026-07-25-c/ops", Jason.encode!(op))
    assert json_response(resp, 200)["ok"] == true
  end
end
```

Before finalizing the ops test, read one existing `apply_op` test in `bulldocs_ingest_controller_test.exs` and copy its exact op JSON shape (`"op"` kind names differ per Patch vocabulary — mirror a known-good one).

- [ ] **Step 2: Run to verify failure** — `cd api && mix test test/barkpark_web/controllers/bulldocs_sessions_controller_test.exs` → FAIL (404 route)

- [ ] **Step 3: Routes** in `bulldocs.ex` `register_routes/1` (after the paper routes at :204):

```elixir
{:post, "/bulldocs/sessions", BarkparkWeb.BulldocsIngestController, :ingest_session, auth: :ingest},
{:get, "/bulldocs/sessions/:slug", BarkparkWeb.BulldocsIngestController, :show_session, auth: :ingest},
{:post, "/bulldocs/sessions/:slug/ops", BarkparkWeb.BulldocsIngestController, :apply_session_op, auth: :ingest},
```

- [ ] **Step 4: Controller actions** in `bulldocs_ingest_controller.ex` (mirror `ingest_blocks/4`'s key-whitelist + scope + response shape; read :94-160 first):

```elixir
@session_keys ~w(slug title blocks style tags description harness session_uuid cwd machine git_head git_branch started_at ended_at transcript status)

def ingest_session(conn, %{"slug" => slug} = params) when is_binary(slug) and slug != "" do
  attrs = params |> Map.take(@session_keys) |> Map.put_new("blocks", [])
  attrs = put_scope_attrs(attrs, conn, params)   # reuse however ingest_blocks threads scope

  case Barkpark.Content.upsert_blocks_doc("session", attrs) do
    {:ok, _doc} -> json(conn, %{ok: true, slug: slug})
    {:error, reason} -> respond_ingest_error(conn, reason)  # reuse existing error clauses
  end
end

def ingest_session(conn, _params),
  do: conn |> put_status(422) |> json(%{ok: false, error: "slug required"})

def show_session(conn, %{"slug" => slug}) do
  case Barkpark.Content.get_blocks_doc(slug, "session", dataset(conn)) do
    nil -> conn |> put_status(404) |> json(%{ok: false, error: "not_found"})
    doc ->
      json(conn, Map.merge(
        Map.take(doc.content || %{}, @session_keys ++ ["events"]),
        %{"slug" => slug, "rev" => doc.rev}
      ))
  end
end

def apply_session_op(conn, %{"slug" => slug} = params) do
  op = Map.delete(params, "slug")
  dataset = params["dataset"] || Barkpark.Content.paper_default_dataset()

  case Barkpark.Content.apply_document_block_op(slug, "session", op, dataset) do
    {:ok, %{block_id: block_id, position: position}} ->
      json(conn, %{ok: true, slug: slug, block_id: block_id, position: position})
    {:error, reason} -> respond_op_error(conn, reason)  # reuse existing 404/422 clauses
  end
end
```

Adapt helper names (`put_scope_attrs`, `respond_ingest_error`, `respond_op_error`, `dataset/1`) to what actually exists in the controller — reuse, don't invent parallel helpers.

- [ ] **Step 5: Pane dispatch** in `pane_builder.ex`. At :415-418 replace the equality with the whitelist and fetch by actual type:

```elixir
Content.blocks_type?(type_name) ->
  case rest do
    [slug | _] ->
      case Content.get_blocks_doc(slug, type_name, dataset, scope_kw) do
```

At :200-206 (`walk_path(["open", type, id | _], ...)`), change `if type == "paper" do` → `if Content.blocks_type?(type) do` and the inner `Content.get_paper(id, dataset, scope(opts))` → `Content.get_blocks_doc(id, type, dataset, scope(opts))`. Keep the `%{view: :paper, ...}` pane shape (sessions open in the paper pane by design).

- [ ] **Step 6: Run** — `cd api && mix test test/barkpark_web/controllers/bulldocs_sessions_controller_test.exs test/barkpark_web/controllers/bulldocs_ingest_controller_test.exs` and any pane_builder test (`ls api/test/**/pane_builder*`). Expected: PASS.

- [ ] **Step 7: Commit** — `feat(sessions): bulldocs session routes + paper-pane dispatch via blocks whitelist`

---

### Task 4: Events append endpoint (server-stamped, CAS)

**Files:**
- Create: `api/lib/barkpark/content/sessions.ex`
- Modify: `api/lib/barkpark/plugins/bulldocs.ex` (route)
- Modify: `api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex` (action)
- Test: `api/test/barkpark/content/session_events_test.exs`

**Interfaces:**
- Produces: `Barkpark.Content.Sessions.append_event(slug, kind, attrs, dataset \\ "production")` → `{:ok, %{count: n}} | {:error, :not_found | :invalid_kind | :stale}`; `POST /v1/plugins/bulldocs/sessions/:slug/events` with JSON `{"kind": k, "ref": r, "note": n}`.
- Consumes: `Content.get_blocks_doc/4` (Task 2). CAS pattern copied from `api/lib/barkpark/tasks/mutations.ex:105-165`; ts pattern from `api/lib/barkpark/tasks/stamp.ex:125-131`.

- [ ] **Step 1: Write the failing test**

```elixir
# api/test/barkpark/content/session_events_test.exs
defmodule Barkpark.Content.SessionEventsTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.Content
  alias Barkpark.Content.Sessions

  setup do
    {:ok, _} = Content.upsert_blocks_doc("session",
      %{"slug" => "session-ev-test", "title" => "E", "status" => "open"})
    :ok
  end

  test "appends events in order with server ts" do
    assert {:ok, %{count: 1}} =
             Sessions.append_event("session-ev-test", "task-closed", %{"ref" => "task-abc"})
    assert {:ok, %{count: 2}} =
             Sessions.append_event("session-ev-test", "push", %{"note" => "pushed main"})

    doc = Content.get_blocks_doc("session-ev-test", "session", "production")
    [e1, e2] = doc.content["events"]
    assert e1["kind"] == "task-closed"
    assert e1["ref"] == "task-abc"
    assert {:ok, _, _} = DateTime.from_iso8601(e1["ts"])
    assert e2["kind"] == "push"
  end

  test "rejects unknown kinds" do
    assert {:error, :invalid_kind} =
             Sessions.append_event("session-ev-test", "deployed", %{})
  end

  test "unknown slug" do
    assert {:error, :not_found} = Sessions.append_event("session-nope", "note", %{})
  end
end
```

- [ ] **Step 2: Run to verify failure** — module `Sessions` undefined.

- [ ] **Step 3: Implement** `api/lib/barkpark/content/sessions.ex` — copy the advisory-lock + CAS-on-rev core from `mutations.ex:105-165` (lock key `"session:#{slug}"`, `Repo.update_all` guarded on observed rev, one retry on `:stale`):

```elixir
defmodule Barkpark.Content.Sessions do
  @moduledoc "Append-only event trail on type:session documents. Server-stamped ts."
  import Ecto.Query
  alias Barkpark.{Repo, Content}
  alias Barkpark.Content.Document

  @event_kinds ["paper-published", "task-closed", "epic-wave-complete", "push", "note"]
  def event_kinds, do: @event_kinds

  def append_event(slug, kind, attrs \\ %{}, dataset \\ "production")

  def append_event(_slug, kind, _attrs, _dataset) when kind not in @event_kinds,
    do: {:error, :invalid_kind}

  def append_event(slug, kind, attrs, dataset) do
    Repo.transaction(fn ->
      _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["session:#{slug}"])

      case Content.get_blocks_doc(slug, "session", dataset) do
        nil ->
          Repo.rollback(:not_found)

        %Document{} = doc ->
          event =
            %{"ts" => DateTime.utc_now() |> DateTime.to_iso8601(), "kind" => kind}
            |> maybe_put("ref", attrs["ref"])
            |> maybe_put("note", attrs["note"])

          events = (doc.content["events"] || []) ++ [event]
          new_content = Map.put(doc.content, "events", events)

          {rows, _} =
            from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
            |> Repo.update_all(
              set: [content: new_content, rev: Ecto.UUID.generate(), updated_at: DateTime.utc_now()]
            )

          if rows == 1, do: %{count: length(events)}, else: Repo.rollback(:stale)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
```

Before writing, check how `mutations.ex` generates `rev` (`generate_rev()`) and whether `Document` rows for published docs need the draft/published pair updated — mirror EXACTLY what `update_paper_refs_by_id` does about draft vs published rows (if it targets a specific row via `find_task_by_doc_id`-style resolution, resolve the session document the same way `get_blocks_doc` does and update that row; keep both draft+published consistent if the papers core does).

- [ ] **Step 4: Route + controller action.** Route in `bulldocs.ex` after the ops route:

```elixir
{:post, "/bulldocs/sessions/:slug/events", BarkparkWeb.BulldocsIngestController, :append_session_event, auth: :ingest},
```

Controller:

```elixir
def append_session_event(conn, %{"slug" => slug} = params) do
  case Barkpark.Content.Sessions.append_event(slug, params["kind"], params, dataset(conn)) do
    {:ok, %{count: count}} -> json(conn, %{ok: true, slug: slug, count: count})
    {:error, :invalid_kind} ->
      conn |> put_status(422)
      |> json(%{ok: false, error: "invalid_kind", allowed: Barkpark.Content.Sessions.event_kinds()})
    {:error, :not_found} -> conn |> put_status(404) |> json(%{ok: false, error: "not_found"})
    {:error, :stale} -> conn |> put_status(409) |> json(%{ok: false, error: "conflict_retry"})
  end
end
```

Add two controller tests to `bulldocs_sessions_controller_test.exs` (201-style happy path asserting `count`, and 422 with `allowed` list).

- [ ] **Step 5: Run** — `cd api && mix test test/barkpark/content/session_events_test.exs test/barkpark_web/controllers/bulldocs_sessions_controller_test.exs` → PASS

- [ ] **Step 6: Commit** — `feat(sessions): append-only event trail with server-stamped ts`

---

### Task 5: Tasks — `sessions` field + `/v1/tasks/:id/sessions` endpoint

**Files:**
- Modify: `api/lib/barkpark/tasks/schema.ex` (add field after `attachments` at :535-544; `papers` field description at :670-677)
- Modify: `api/lib/barkpark/tasks/mutations.ex` (:105-165 — generalize)
- Modify: `api/lib/barkpark_web/controllers/tasks_controller.ex` (clone `papers/2` at :1140-1159)
- Modify: `api/lib/barkpark/plugins/tasks.ex` (route near :453)
- Test: `api/test/barkpark_web/controllers/tasks_sessions_ref_test.exs`

**Interfaces:**
- Produces: task field `sessions` (arrayOf reference refType `session`); `POST /v1/tasks/:doc_id/sessions` `{add: [...], remove: [...]}` → `%{ok: true, doc: ...}`; `Tasks.update_session_refs_by_id/4`.
- Consumes: nothing from other tasks (session docs referenced by slug string; no FK).

- [ ] **Step 1: Write the failing test** (conventions from `tasks_controller_test.exs` — copy its `setup` block with `Auth.create_token`, `TenancyFixtures.ensure_default_scope!()`, `register_schemas!`, `mk_task!`, `authed/1`, `uniq/1` helpers verbatim from that file):

```elixir
# api/test/barkpark_web/controllers/tasks_sessions_ref_test.exs
defmodule BarkparkWeb.TasksSessionsRefTest do
  use BarkparkWeb.ConnCase, async: false
  # copy setup/helpers from tasks_controller_test.exs

  test "appends, dedupes, and removes session refs", %{conn: conn, scope: scope} do
    task = mk_task!(uniq("sess-ref"), scope, %{})

    resp = conn |> authed()
           |> post("/v1/tasks/#{task_doc_id(task)}/sessions",
                   Jason.encode!(%{add: ["session-2026-07-25-x"]}))
    assert Jason.decode!(resp.resp_body)["ok"] == true
    assert Jason.decode!(resp.resp_body)["doc"]["sessions"] == ["session-2026-07-25-x"]

    # idempotent append
    resp2 = conn |> authed()
            |> post("/v1/tasks/#{task_doc_id(task)}/sessions",
                    Jason.encode!(%{add: ["session-2026-07-25-x"]}))
    assert Jason.decode!(resp2.resp_body)["doc"]["sessions"] == ["session-2026-07-25-x"]

    # remove
    resp3 = conn |> authed()
            |> post("/v1/tasks/#{task_doc_id(task)}/sessions",
                    Jason.encode!(%{remove: ["session-2026-07-25-x"]}))
    assert Jason.decode!(resp3.resp_body)["doc"]["sessions"] == []
  end

  test "404 for unknown task", %{conn: conn} do
    resp = conn |> authed()
           |> post("/v1/tasks/task-does-not-exist/sessions", Jason.encode!(%{add: ["s"]}))
    assert resp.status == 404
  end
end
```

(`task_doc_id/1`: use however `tasks_controller_test.exs` derives the doc id it posts to — copy that.)

- [ ] **Step 2: Run to verify failure** — 404 route.

- [ ] **Step 3: Schema field** — insert after `attachments` (:544):

```elixir
%{
  "name" => "sessions",
  "title" => "Sessions",
  "type" => "arrayOf",
  "ordered" => false,
  "group" => "system",
  "description" =>
    "session doc-ids this task was worked in, via POST /v1/tasks/:id/sessions {add,remove}. Arrays of references do not server-expand; fetch each by id.",
  "of" => %{"type" => "reference", "refType" => "session"}
},
```

Run `cd api && mix test test/barkpark/tasks/tasks_schema_dossier_test.exs` (or wherever the group-invariant test lives) and fix if it enumerates fields.

- [ ] **Step 4: Generalize the mutation.** In `mutations.ex`, rename the :105-165 core to a private `update_ref_list_by_id(task_id, field, add, remove, caller_token_id)` parameterized on the content key (`"papers"` / `"sessions"`), with two public wrappers:

```elixir
def update_paper_refs_by_id(task_id, add, remove, caller),
  do: update_ref_list_by_id(task_id, "papers", add, remove, caller)

def update_session_refs_by_id(task_id, add, remove, caller),
  do: update_ref_list_by_id(task_id, "sessions", add, remove, caller)
```

Inside, generalize `papers_of/1` (:174) to `refs_of(content, field)`. Keep the advisory lock key, `@event_task_referenced` mutation event, and broadcast exactly as-is for both fields.

- [ ] **Step 5: Controller + route.** Clone `papers/2` (:1140-1159) as `sessions/2` calling `Tasks.update_session_refs_by_id/4`. Route in `plugins/tasks.ex` next to :453:

```elixir
{:post, "/tasks/:doc_id/sessions", BarkparkWeb.TasksController, :sessions, auth: :token_root},
```

- [ ] **Step 6: Run** — `cd api && mix test test/barkpark_web/controllers/tasks_sessions_ref_test.exs test/barkpark_web/controllers/tasks_controller_test.exs` → PASS (papers regression green)

- [ ] **Step 7: Commit** — `feat(sessions): task sessions[] refs + /v1/tasks/:id/sessions endpoint`

---

### Task 6: `bp session` manifest verbs

**Files:**
- Modify: `api/lib/barkpark/plugins/bulldocs.ex` (`cli_commands/0` at :254)
- Test: `api/test/barkpark/plugins/bulldocs_cli_commands_test.exs` (create; or extend an existing manifest test if one asserts bulldocs command ids — check `grep -rl "bulldocs.publish" api/test` first)

**Interfaces:**
- Consumes: routes from Tasks 3-5.
- Produces: manifest entries `session.open`, `session.log`, `session.publish`, `session.view`, `session.link-task` → the Go CLI materializes `bp session <verb>` with zero Go changes (manifest-driven).

- [ ] **Step 1: Failing test**

```elixir
defmodule Barkpark.Plugins.BulldocsCliCommandsTest do
  use ExUnit.Case, async: true

  test "session verb group is declared" do
    ids = Barkpark.Plugins.Bulldocs.cli_commands() |> Enum.map(& &1.id)
    for id <- ~w(session.open session.log session.publish session.view session.link-task) do
      assert id in ids, "missing #{id}"
    end
  end
end
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Add the five maps** to `cli_commands/0` (exact shape of `bulldocs.publish` at :256-279):

```elixir
%{
  id: "session.open",
  noun: "session", verb: "open",
  summary: "Open a living session document at session start (status: open, metadata seeded).",
  http: %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions"},
  auth_tier: "ingest",
  args: [%{name: "slug", required: true, type: "slug", summary: "Session slug (session-YYYY-MM-DD-<topic>)."}],
  flags: [%{name: "file", type: "file", summary: "Metadata payload (fields, tags, description; blocks optional)."}],
  writes: true, batch: false, paginated: false, dry_run: false,
  default_output: "minimal", scoped_prefix: nil
},
%{
  id: "session.log",
  noun: "session", verb: "log",
  summary: "Append one milestone event to an open session (server stamps ts).",
  http: %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions/:slug/events"},
  auth_tier: "ingest",
  args: [%{name: "slug", required: true, type: "slug", summary: "Session slug."}],
  flags: [
    %{name: "kind", type: "string",
      summary: "Event kind: paper-published | task-closed | epic-wave-complete | push | note."},
    %{name: "ref", type: "string", summary: "Related doc id (task id, paper slug, commit SHA)."},
    %{name: "note", type: "string", summary: "Short free-text note."}
  ],
  writes: true, batch: false, paginated: false, dry_run: false,
  default_output: "minimal", scoped_prefix: nil
},
%{
  id: "session.publish",
  noun: "session", verb: "publish",
  summary: "Upsert session synthesis blocks + metadata (checkpoint or close).",
  http: %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions"},
  auth_tier: "ingest",
  args: [%{name: "slug", required: true, type: "slug", summary: "Session slug."}],
  flags: [%{name: "file", type: "file", summary: "Payload: blocks + fields (status: closed on final close)."}],
  writes: true, batch: false, paginated: false, dry_run: false,
  default_output: "minimal", scoped_prefix: nil
},
%{
  id: "session.view",
  noun: "session", verb: "view",
  summary: "Read a session back: metadata + event trail + synthesis blocks.",
  http: %{method: "GET", path_template: "/v1/plugins/bulldocs/sessions/:slug"},
  auth_tier: "ingest",
  args: [%{name: "slug", required: true, type: "slug", summary: "Session slug."}],
  flags: [],
  writes: false, batch: false, paginated: false, dry_run: false,
  default_output: "json", scoped_prefix: nil
},
%{
  id: "session.link-task",
  noun: "session", verb: "link-task",
  summary: "Stamp a task with the session it was worked in (appends to the task's sessions[]).",
  http: %{method: "POST", path_template: "/v1/tasks/:doc_id/sessions"},
  auth_tier: "read",
  args: [%{name: "doc_id", required: true, type: "string", summary: "Task doc id."}],
  flags: [%{name: "add", type: "string", summary: "Session slug to add."}],
  writes: true, batch: false, paginated: false, dry_run: false,
  default_output: "minimal", scoped_prefix: nil
},
```

Before committing, verify flag→body mapping: check how the manifest engine maps flags to JSON body for POST verbs (look at how `task.move` flags reach the controller, `internal/manifest/` on the Go side if needed). If flags map to body keys 1:1, `session.log --kind` arrives as `{"kind": ...}` — which is what the controller expects. If `link-task`'s `--add` needs to be a list, accept a comma string in `Params.string_list` (it already handles both — verify with :1141 `Params.string_list(params["add"])`).

- [ ] **Step 4: Run test** → PASS.

- [ ] **Step 5: Commit** — `feat(sessions): bp session verb group on the bulldocs manifest`

---

### Task 7: Lifecycle + resume skills, scrub helper

**Files:**
- Create: `.claude/skills/session/SKILL.md`
- Create: `.claude/skills/session/helpers/scrub.sh`
- Create: `.claude/skills/session-resume/SKILL.md`

**Interfaces:**
- Consumes: `bp session open|log|publish|view|link-task` (Task 6), `bp media upload` (exists).
- Produces: skill procedures; scrub.sh reads a file path arg, writes scrubbed copy to stdout.

- [ ] **Step 1: scrub.sh** (portable bash 3.2, no gnu-only flags):

```bash
#!/usr/bin/env bash
# scrub.sh <file> — redact known secret shapes; scrubbed content to stdout.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: scrub.sh <file>" >&2; exit 2; }

sed -E \
  -e 's/bp_(admin|ingest|read|write)_[A-Za-z0-9_-]+/[REDACTED-BP-TOKEN]/g' \
  -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/g' \
  -e 's/(BARKPARK_[A-Z_]*TOKEN["'\'' ]*[:=][" '\'']*)[^"'\'' ,}]+/\1[REDACTED]/g' \
  -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED-GH-TOKEN]/g' \
  -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED-GH-TOKEN]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g' \
  -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END [A-Z ]*PRIVATE KEY-----/[REDACTED-PRIVATE-KEY]/g' \
  "$1"
```

- [ ] **Step 2: Verify scrub.sh manually**

```bash
chmod +x .claude/skills/session/helpers/scrub.sh
printf 'token bp_admin_abc123 and Bearer eyJx.y-z and ghp_0123456789abcdefghij ok\n' > /tmp/scrub-fixture
.claude/skills/session/helpers/scrub.sh /tmp/scrub-fixture
```

Expected output: `token [REDACTED-BP-TOKEN] and Bearer [REDACTED] and [REDACTED-GH-TOKEN] ok`

- [ ] **Step 3: `.claude/skills/session/SKILL.md`** — frontmatter `name: session` + trigger-heavy description (pattern: `.claude/skills/fleet-listener/SKILL.md`). Body must contain, concretely:
  - **Open** (at session start / on invocation): compute slug `session-$(date +%Y-%m-%d)-<topic>`; build meta JSON (harness, session_uuid if known, cwd `$(pwd)`, machine `$(hostname -s)`, git_head `$(git rev-parse HEAD)`, git_branch, started_at, `status: open`, description, tags — weighted shape, `sessions` tag + one topic tag, each a published `type:tag` doc); `bp session open <slug> --file meta.json`. Keep the slug in conversation context.
  - **Log** (after every milestone): the four wired milestones (paper published → `--kind paper-published --ref <paper-slug>`; task closed → `--kind task-closed --ref <task-id>`; epic wave sealed → `--kind epic-wave-complete --ref <wave-paper>`; successful `git push` → `--kind push --ref <sha>`). **Non-blocking**: a failed log is a loud warning, never a reason to abort the milestone.
  - **Checkpoint**: rewrite synthesis blocks (template: current task · progress · key files · decisions · next steps · learnings) → `bp session publish <slug> --file session.json`; locate transcript (Claude Code: `~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl` where `<cwd-slug>` is the cwd with `/` → `-`; Codex: its sessions dir; missing → synthesis-only, say so loudly); scrub → `helpers/scrub.sh <transcript> > <scratchpad>/scrubbed.jsonl`; `bp media upload --file <scratchpad>/scrubbed.jsonl` (100 MB cap — over-cap: fail loud, instruct splitting); set `transcript` ref in next publish.
  - **Close**: final checkpoint with `status: closed` + `ended_at`; `bp session link-task <task-id> <slug> --add <slug>` for every task claimed/stamped/closed this session; print `On the other machine: /session-resume <slug>`.
- [ ] **Step 4: `.claude/skills/session-resume/SKILL.md`** — frontmatter `name: session-resume`. Body: `bp session view <slug> -o json`; load synthesis + metadata + events into context; warn on cwd/repo/branch mismatch vs metadata; `bp session publish <slug>` with `status: resumed` (metadata-only upsert); transcript offered as URL (`<server>/files/...` from the mediaAsset doc), never auto-downloaded; recent-sessions one-liner: `bp doc query session -o json | jq -r '.documents[] | select(.status != "superseded") | ._id'`.
- [ ] **Step 5: Commit** — `feat(sessions): session lifecycle + resume skills with scrub helper`

---

### Task 8: Doc wiring + doc gates

**Files:**
- Modify: `docs/cheatsheets/papers.md` (one line: after publishing a paper, log it to the open session)
- Modify: `.claude/skills/fleet-listener/SKILL.md` (close step: `bp session log <slug> --kind task-closed --ref <task-id>` when a session is open)
- Modify: the bp-epic-cycle workflow definition (locate: `grep -rl "bp-epic-cycle" .claude/`) — wave-seal step logs `--kind epic-wave-complete`
- Modify: `CLAUDE.md` "Task layer + session completion" — add to the checklist: step 3 gains "log task closes to the open session (`bp session log`)"; step 4 gains "then `bp session log <slug> --kind push --ref <sha>`" (2 lines total; do NOT touch Golden Rules / Past Mistakes — verbatim-exempt)
- Modify: `api/CLAUDE.md` §Bulldocs — one line: sessions are the second blocks type; routes + whitelist

**Interfaces:** none produced; consumes verb names from Task 6.

- [ ] **Step 1: Make the five edits.** Each is 1-3 lines, phrased as an instruction at the point where the milestone already happens. Keep within each doc's byte budget.
- [ ] **Step 2: Run doc gates**

```bash
scripts/docs-anchors-check.sh && scripts/check-doc-budgets.sh
```

Expected: both pass. If an anchored card references a file touched in Tasks 1-6 (likely `docs/cards/plugins.md` or `api/CLAUDE.md` anchors on bulldocs/pane_builder), update that card's anchor text minimally until the check passes.

- [ ] **Step 3: Commit** — `docs(sessions): wire session logging into milestone procedures`

---

### Task 9: Full gate, PR, merge, live smoke

**Files:** none new.

- [ ] **Step 1: Full API test suite** — `cd api && mix test`. Expected: green. Fix anything red before proceeding (report count).
- [ ] **Step 2: Compile check for warnings** — `cd api && mix compile --warnings-as-errors` (if the repo's CI uses it — check `docs/ops/merge-gates.md`; run whatever gates it names).
- [ ] **Step 3: Push branch + PR**

```bash
git push -u origin feat/session-handoff
gh pr create --title "feat(sessions): first-class session type — living session docs, bp session verbs, task session refs" \
  --body "Implements docs/superpowers/specs/2026-07-25-session-handoff-design.md (paper: /papers/session-handoff-design).

- session schema (blocks + metadata + append-only events[]) registered by Bulldocs
- blocks-type whitelist {paper, session}: generalized upsert, paper-pane dispatch, ops path
- POST/GET /v1/plugins/bulldocs/sessions[/:slug][/ops|/events]
- task sessions[] refs + POST /v1/tasks/:id/sessions (CAS core generalized from /papers)
- bp session open|log|publish|view|link-task (manifest-only, no Go changes)
- session lifecycle + resume skills, scrub helper, milestone doc wiring

v1.5 auto-log follow-up: task-bc34e83515bbd91f.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 4: Merge when gates are green** (`gh pr checks --watch`), then on the MAIN checkout run `make update` (never a branch switch), and remove the worktree.
- [ ] **Step 5: Live smoke against the connected server** once it carries the build (Guerrilla updates on its own deploy cadence — if the new manifest isn't live yet, smoke against local `make dev` instead):

```bash
bp session open session-2026-07-25-smoke --file /dev/stdin <<'EOF'
{"title":"Smoke","status":"open","description":"Smoke test of the session lifecycle — open, one event, view, close.","tags":[{"tag":"sessions","strength":60,"rationale":"Lifecycle smoke test."}]}
EOF
bp session log session-2026-07-25-smoke --kind note --note "first event"
bp session view session-2026-07-25-smoke -o json | jq '.events'
```

Expected: view shows one `note` event with a server ts.
- [ ] **Step 6: Close out** — update the wave/session records per CLAUDE.md session-completion; `git status` clean; report results.

---

## Self-review notes

- Spec coverage: schema+registration (T1), generalization set incl. pane_builder both gates (T2-T3), events (T4), task refs + endpoint (T5), five CLI verbs (T6), both skills + scrub (T7), all four milestone wirings + api/CLAUDE.md (T8), tests + smoke incl. crash-shaped flow (T4/T9). Publish wall: session ingest flows through the same `upsert_blocks_doc` path; T3's key whitelist passes `tags`/`description` through — if the wall validator rejects session opens for missing tags in practice, the skill supplies them at open (per spec) and the T9 smoke exercises exactly that payload.
- Deliberately NOT in plan (spec-confirmed out of scope): harness hooks, auto-list, custom Studio pane, cross-server sync, X-Barkpark-Session auto-log (filed: task-bc34e83515bbd91f).
- Type consistency check: `upsert_blocks_doc/3`, `get_blocks_doc/4`, `blocks_type?/1`, `Sessions.append_event/4`, `update_session_refs_by_id/4` — names used identically in Tasks 2-6.
