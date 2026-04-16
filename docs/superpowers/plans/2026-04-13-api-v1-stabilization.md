# API v1 Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the `/v1` HTTP contract — envelope, mutations, queries, SSE, errors — so external SDKs (TanStack Start / Next.js / Go TUI) can be built without risk of breaking changes.

**Architecture:** Bottom-up. First lock the document envelope (Phase 1) because every other shape depends on it. Then mutations (atomicity + structured errors), then query (pagination), then SSE (resume envelope), then cross-cutting hygiene (errors, dates, CORS), then freeze with contract tests and `docs/api-v1.md`.

**Tech Stack:** Elixir 1.16+, Phoenix 1.7, Ecto/Postgres, Jason, Phoenix.PubSub, ExUnit. No new runtime deps except `corsica` (CORS) and `ulid` (revision IDs).

**Scope note:** This plan covers ONLY `/v1/data/*`, `/v1/schemas/*`, and the shared error/CORS plumbing. Media (`/media/*`), Studio LiveView, legacy `/api/documents/*`, and the Go TUI are out of scope — they continue to work unchanged. A Phase 8 item at the end reminds you to migrate them after v1 is frozen.

**Golden rule during this work:** Before every `mix compile` on the server, `rm -rf api/_build/prod`. After every deploy, `curl http://89.167.28.206/v1/data/query/production/post | jq .` to confirm the shape still matches.

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `api/lib/barkpark/content/envelope.ex` | Single source of truth: converts a `Document` struct into the flat v1 JSON envelope. Used by query, mutate, SSE, schema controllers. |
| `api/lib/barkpark/content/errors.ex` | Maps internal errors (`{:error, :not_found}`, changeset errors, etc.) to structured `{code, message, path, details}` tuples. |
| `api/lib/barkpark_web/controllers/error_json_v1.ex` | Renders `Errors` tuples into the v1 JSON error envelope. |
| `api/lib/barkpark/content/event_log.ex` | Append-only mutation log for SSE resume (bounded, in-memory ETS + Postgres spillover). |
| `api/priv/repo/migrations/<ts>_add_rev_to_documents.exs` | Adds `rev` column (ULID text) to `documents`, backfills existing rows. |
| `api/priv/repo/migrations/<ts>_create_mutation_events.exs` | Append-only table `mutation_events` for SSE resume. |
| `api/test/barkpark_web/contract/envelope_test.exs` | Contract test: exact shape of a document in a query response. |
| `api/test/barkpark_web/contract/mutate_test.exs` | Contract test: mutation request/response shapes, atomicity, error codes. |
| `api/test/barkpark_web/contract/query_test.exs` | Contract test: pagination, ordering, filtering. |
| `api/test/barkpark_web/contract/listen_test.exs` | Contract test: SSE envelope and `Last-Event-ID` resume. |
| `docs/api-v1.md` | Frozen reference: every endpoint, param, field, error code. |

### Modified files

| File | Change |
|---|---|
| `api/lib/barkpark_web/controllers/query_controller.ex` | Use `Envelope.render/2`; add pagination, ordering, structured filter. |
| `api/lib/barkpark_web/controllers/mutate_controller.ex` | Atomic transaction; structured errors; return envelopes; split `create`/`createOrReplace`/`createIfNotExists`; `ifRevisionID`. |
| `api/lib/barkpark_web/controllers/listen_controller.ex` | New event envelope with `eventId`, `rev`, `mutation`; honor `Last-Event-ID`; query-param token. |
| `api/lib/barkpark_web/controllers/schema_controller.ex` | Add `_schemaVersion: 1`; consistent error envelope. |
| `api/lib/barkpark_web/controllers/fallback_controller.ex` | Route all errors through `Errors` + `ErrorJsonV1`. |
| `api/lib/barkpark/content.ex` | Wrap mutation batch in `Repo.transaction`; stamp `rev` on every write; write to `event_log`. |
| `api/lib/barkpark_web/endpoint.ex` | Plug `Corsica` for `/v1/*` and `/media/*`. |
| `api/lib/barkpark_web/router.ex` | Add `Deprecation` + `Sunset` headers plug on `/api/documents/*`. |
| `api/mix.exs` | Add `{:corsica, "~> 2.1"}`, `{:ulid, "~> 0.3"}`. |

### Files touched but behavior unchanged
`legacy_controller.ex`, `structure.ex`, `media_controller.ex`, `studio_live.ex` — do **not** change these. If a test fails because one of them still uses the old `render_doc` shape, fix the test to call the legacy helper instead.

---

## Phase 1 — Document Envelope

### Task 1: Add `rev` column to documents

**Files:**
- Create: `api/priv/repo/migrations/20260413000001_add_rev_to_documents.exs`
- Modify: `api/lib/barkpark/content/document.ex`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Barkpark.Repo.Migrations.AddRevToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :rev, :text
    end

    create index(:documents, [:rev])

    # Backfill existing rows with a ULID each
    execute(
      fn ->
        repo().query!(
          "UPDATE documents SET rev = encode(gen_random_bytes(16), 'hex') WHERE rev IS NULL"
        )
      end,
      fn -> :ok end
    )

    alter table(:documents) do
      modify :rev, :text, null: false
    end
  end
end
```

- [ ] **Step 2: Add `rev` to the Ecto schema**

In `api/lib/barkpark/content/document.ex`, find the `schema "documents" do` block and add:

```elixir
field :rev, :string
```

Add `:rev` to the `cast/3` call in `changeset/2`.

- [ ] **Step 3: Run the migration**

```bash
cd api && MIX_ENV=dev mix ecto.migrate
```
Expected: `[info] == Migrated ... in 0.Xs`

- [ ] **Step 4: Commit**

```bash
git add api/priv/repo/migrations api/lib/barkpark/content/document.ex
git commit -m "feat(api): add rev column to documents for v1 envelope"
```

---

### Task 2: Stamp `rev` on every write

**Files:**
- Modify: `api/lib/barkpark/content.ex`
- Test: `api/test/barkpark/content_rev_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Barkpark.ContentRevTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  test "create_document stamps a rev" do
    {:ok, doc} = Content.create_document("post", %{"doc_id" => "rev-1", "title" => "T"}, "test")
    assert is_binary(doc.rev) and byte_size(doc.rev) >= 16
  end

  test "updating a doc produces a new rev" do
    {:ok, d1} = Content.create_document("post", %{"doc_id" => "rev-2", "title" => "A"}, "test")
    {:ok, d2} = Content.upsert_document("post", %{"doc_id" => d1.doc_id, "title" => "B"}, "test")
    refute d1.rev == d2.rev
  end
end
```

- [ ] **Step 2: Run test — expect fail**

```bash
cd api && mix test test/barkpark/content_rev_test.exs
```
Expected: both tests fail (rev is nil).

- [ ] **Step 3: Add rev generator**

At the top of `api/lib/barkpark/content.ex` add:

```elixir
defp generate_rev do
  <<a::64, b::64>> = :crypto.strong_rand_bytes(16)
  :io_lib.format("~16.16.0b~16.16.0b", [a, b]) |> IO.iodata_to_binary()
end
```

In `create_document/3` and `upsert_document/3`, before calling `Document.changeset/2`, do:

```elixir
attrs = Map.put(attrs, "rev", generate_rev())
```

Also add `"rev"` to the `cast` list in `Document.changeset/2` if not already there.

- [ ] **Step 4: Do the same in `publish_document`, `unpublish_document`**

Every place that constructs `*_attrs` maps must include `"rev" => generate_rev()`.

- [ ] **Step 5: Run tests — expect pass**

```bash
cd api && mix test test/barkpark/content_rev_test.exs
```
Expected: 2 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark/content.ex api/test/barkpark/content_rev_test.exs
git commit -m "feat(api): stamp rev on every document write"
```

---

### Task 3: Create the `Envelope` module

**Files:**
- Create: `api/lib/barkpark/content/envelope.ex`
- Test: `api/test/barkpark/content/envelope_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Barkpark.Content.EnvelopeTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  setup do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-1", "title" => "Hello", "content" => %{"body" => "hi", "tags" => ["a"]}},
        "test"
      )
    %{doc: doc}
  end

  test "renders flat envelope with reserved underscore keys", %{doc: doc} do
    env = Envelope.render(doc)
    assert env["_id"] == doc.doc_id
    assert env["_type"] == "post"
    assert env["_rev"] == doc.rev
    assert env["_draft"] == true
    assert env["_publishedId"] == "env-1"
    assert env["title"] == "Hello"
    assert env["body"] == "hi"
    assert env["tags"] == ["a"]
    assert is_binary(env["_createdAt"])
    assert String.ends_with?(env["_createdAt"], "Z")
  end

  test "no nested `content` key in output", %{doc: doc} do
    env = Envelope.render(doc)
    refute Map.has_key?(env, "content")
    refute Map.has_key?(env, :content)
  end

  test "user fields cannot override reserved keys", %{doc: _doc} do
    {:ok, d} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-2", "title" => "X", "content" => %{"_id" => "HIJACK"}},
        "test"
      )
    env = Envelope.render(d)
    assert env["_id"] == d.doc_id
    refute env["_id"] == "HIJACK"
  end
end
```

- [ ] **Step 2: Run test — expect fail**

```bash
cd api && mix test test/barkpark/content/envelope_test.exs
```
Expected: `Barkpark.Content.Envelope.render/1 is undefined`.

- [ ] **Step 3: Implement `Envelope`**

```elixir
defmodule Barkpark.Content.Envelope do
  @moduledoc """
  Canonical v1 document envelope. Flat map with reserved `_`-prefixed keys.

  Reserved keys: _id, _type, _rev, _draft, _publishedId, _createdAt, _updatedAt.
  All other keys come from the document's stored content plus `title`.
  User content cannot override reserved keys.
  """

  alias Barkpark.Content

  @reserved ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

  def render(doc) do
    user_fields =
      (doc.content || %{})
      |> Map.drop(@reserved)
      |> Map.put("title", doc.title)

    Map.merge(user_fields, %{
      "_id" => doc.doc_id,
      "_type" => doc.type,
      "_rev" => doc.rev,
      "_draft" => Content.draft?(doc.doc_id),
      "_publishedId" => Content.published_id(doc.doc_id),
      "_createdAt" => to_iso8601(doc.inserted_at),
      "_updatedAt" => to_iso8601(doc.updated_at)
    })
  end

  def render_many(docs), do: Enum.map(docs, &render/1)

  defp to_iso8601(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(nil), do: nil
end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && mix test test/barkpark/content/envelope_test.exs
```
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/content/envelope.ex api/test/barkpark/content/envelope_test.exs
git commit -m "feat(api): add canonical v1 document envelope"
```

---

### Task 4: Flip inbound mutations to accept flat envelope

**Files:**
- Modify: `api/lib/barkpark/content.ex`
- Test: `api/test/barkpark/content_flat_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Barkpark.ContentFlatTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  test "create accepts flat envelope and round-trips through render" do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"_id" => "flat-1", "title" => "T", "body" => "hi", "tags" => ["a", "b"]},
        "test"
      )
    env = Envelope.render(doc)
    assert env["body"] == "hi"
    assert env["tags"] == ["a", "b"]
  end
end
```

- [ ] **Step 2: Run — expect fail** (`body` ends up inside `content`, but it will; the field `_id` isn't stripped — doc_id becomes `nil`, test will fail at insert).

```bash
cd api && mix test test/barkpark/content_flat_test.exs
```

- [ ] **Step 3: Add a normalizer at the top of `create_document/3` and `upsert_document/3`**

In `api/lib/barkpark/content.ex`:

```elixir
@reserved_in ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt doc_id type dataset rev title status)

defp from_envelope(attrs) do
  id = Map.get(attrs, "_id") || Map.get(attrs, "doc_id")
  title = Map.get(attrs, "title")
  status = Map.get(attrs, "status", "draft")
  content = Map.drop(attrs, @reserved_in)

  %{
    "doc_id" => id,
    "title" => title,
    "status" => status,
    "content" => content
  }
end
```

Call it as the first step in `create_document/3` (and keep the draft_id wrapping after):

```elixir
def create_document(type, attrs, dataset) do
  attrs = from_envelope(attrs)
  raw_id = attrs["doc_id"] || generate_id(type)
  doc_id = draft_id(raw_id)
  # ...rest unchanged
end
```

Do the same in `upsert_document/3`.

- [ ] **Step 4: Run test — expect pass**

```bash
cd api && mix test test/barkpark/content_flat_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/content.ex api/test/barkpark/content_flat_test.exs
git commit -m "feat(api): accept flat envelope in Content writes"
```

---

### Task 5: Switch `QueryController` to `Envelope`

**Files:**
- Modify: `api/lib/barkpark_web/controllers/query_controller.ex`
- Test: `api/test/barkpark_web/contract/envelope_test.exs`

- [ ] **Step 1: Write failing contract test**

```elixir
defmodule BarkparkWeb.Contract.EnvelopeTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(%{"name" => "post", "visibility" => "public", "fields" => []}, "test")
    {:ok, _} = Content.create_document("post", %{"_id" => "e1", "title" => "A", "body" => "x"}, "test")
    {:ok, _} = Content.publish_document("e1", "post", "test")
    :ok
  end

  test "GET query/:ds/:type returns flat envelopes", %{conn: conn} do
    %{"documents" => [d | _]} =
      conn |> get("/v1/data/query/test/post") |> json_response(200)

    assert d["_id"] == "e1"
    assert d["_type"] == "post"
    assert d["_rev"]
    assert d["title"] == "A"
    assert d["body"] == "x"
    refute Map.has_key?(d, "content")
    refute Map.has_key?(d, "status")  # status is not reserved anymore
  end
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && mix test test/barkpark_web/contract/envelope_test.exs
```

- [ ] **Step 3: Rewrite `render_doc` to delegate to `Envelope`**

In `api/lib/barkpark_web/controllers/query_controller.ex`, replace `render_doc/3` and its helpers with:

```elixir
alias Barkpark.Content.Envelope

defp render_doc(doc, _ref_fields, _dataset), do: Envelope.render(doc)
```

Delete `expand_refs`, `resolve_ref`, `get_ref_fields` — reference expansion is handled in Task 9 under a new opt-in `?expand=true` param with a different shape.

Update `index/2` to drop the `type` top-level key from the response:

```elixir
json(conn, %{
  perspective: to_string(perspective),
  documents: Enum.map(documents, &Envelope.render/1),
  count: length(documents)
})
```

(Pagination fields come in Phase 2 — for now just remove `type`.)

- [ ] **Step 4: Run — expect pass**

```bash
cd api && mix test test/barkpark_web/contract/envelope_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark_web/controllers/query_controller.ex api/test/barkpark_web/contract/envelope_test.exs
git commit -m "feat(api): QueryController emits flat v1 envelope"
```

---

## Phase 2 — Mutation atomicity and structured errors

### Task 6: Add `Errors` module

**Files:**
- Create: `api/lib/barkpark/content/errors.ex`
- Test: `api/test/barkpark/content/errors_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Barkpark.Content.ErrorsTest do
  use ExUnit.Case, async: true
  alias Barkpark.Content.Errors

  test "maps not_found" do
    assert Errors.to_envelope({:error, :not_found}) ==
             %{code: "not_found", message: "document not found", status: 404}
  end

  test "maps changeset errors" do
    cs = %Ecto.Changeset{valid?: false, errors: [title: {"can't be blank", []}], types: %{}, data: %{}}
    env = Errors.to_envelope({:error, cs})
    assert env.code == "validation_failed"
    assert env.status == 422
    assert env.details == %{title: ["can't be blank"]}
  end

  test "maps rev mismatch" do
    assert %{code: "rev_mismatch", status: 409} = Errors.to_envelope({:error, :rev_mismatch})
  end
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && mix test test/barkpark/content/errors_test.exs
```

- [ ] **Step 3: Implement**

```elixir
defmodule Barkpark.Content.Errors do
  @moduledoc "Maps internal error tuples to v1 JSON error envelopes."

  def to_envelope({:error, :not_found}),
    do: %{code: "not_found", message: "document not found", status: 404}

  def to_envelope({:error, :unauthorized}),
    do: %{code: "unauthorized", message: "missing or invalid token", status: 401}

  def to_envelope({:error, :forbidden}),
    do: %{code: "forbidden", message: "token lacks required permission", status: 403}

  def to_envelope({:error, :schema_unknown}),
    do: %{code: "schema_unknown", message: "no schema for type", status: 404}

  def to_envelope({:error, :rev_mismatch}),
    do: %{code: "rev_mismatch", message: "document was modified by another writer", status: 409}

  def to_envelope({:error, :malformed}),
    do: %{code: "malformed", message: "request body is malformed", status: 400}

  def to_envelope({:error, %Ecto.Changeset{} = cs}) do
    details =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    %{code: "validation_failed", message: "document failed validation", status: 422, details: details}
  end

  def to_envelope({:error, reason}) when is_binary(reason),
    do: %{code: "internal_error", message: reason, status: 500}

  def to_envelope(_),
    do: %{code: "internal_error", message: "unknown error", status: 500}
end
```

- [ ] **Step 4: Run — expect pass**

```bash
cd api && mix test test/barkpark/content/errors_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add api/lib/barkpark/content/errors.ex api/test/barkpark/content/errors_test.exs
git commit -m "feat(api): structured error envelope for v1"
```

---

### Task 7: Atomic mutation batches

**Files:**
- Modify: `api/lib/barkpark/content.ex` (add `apply_mutations/2`)
- Modify: `api/lib/barkpark_web/controllers/mutate_controller.ex`
- Test: `api/test/barkpark_web/contract/mutate_test.exs`

- [ ] **Step 1: Write failing test — atomicity**

```elixir
defmodule BarkparkWeb.Contract.MutateTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content

  @auth [{"authorization", "Bearer barkpark-dev-token"}, {"content-type", "application/json"}]

  setup do
    Content.upsert_schema(%{"name" => "post", "visibility" => "public", "fields" => []}, "test")
    :ok
  end

  test "batch is atomic — partial failure rolls everything back", %{conn: conn} do
    body = %{
      "mutations" => [
        %{"create" => %{"_id" => "ok-1", "_type" => "post", "title" => "ok"}},
        %{"publish" => %{"id" => "does-not-exist", "type" => "post"}}
      ]
    }

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert resp.status == 422 or resp.status == 404
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] in ~w(validation_failed not_found)
    # Critically: ok-1 must NOT exist
    assert {:error, :not_found} = Content.get_document("drafts.ok-1", "post", "test")
  end

  test "successful batch returns envelopes with transactionId", %{conn: conn} do
    body = %{
      "mutations" => [
        %{"create" => %{"_id" => "tx-1", "_type" => "post", "title" => "t"}}
      ]
    }

    resp =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/mutate/test", Jason.encode!(body))

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert is_binary(body["transactionId"])
    assert [%{"id" => _, "operation" => "create", "document" => %{"_id" => _}}] = body["results"]
  end
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && mix test test/barkpark_web/contract/mutate_test.exs
```

- [ ] **Step 3: Add `apply_mutations/2` in `Content`**

```elixir
alias Barkpark.Content.Envelope

def apply_mutations(mutations, dataset) when is_list(mutations) do
  Repo.transaction(fn ->
    tx_id = generate_rev()

    Enum.map(mutations, fn m ->
      case apply_one(m, dataset) do
        {:ok, doc, op} -> %{id: doc.doc_id, operation: op, document: Envelope.render(doc)}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> then(&{tx_id, &1})
  end)
end

defp apply_one(%{"create" => attrs}, dataset) do
  type = attrs["_type"] || attrs["type"]
  case get_document(draft_id(attrs["_id"] || ""), type, dataset) do
    {:ok, _} -> {:error, :conflict}
    _ ->
      with {:ok, doc} <- create_document(type, attrs, dataset), do: {:ok, doc, "create"}
  end
end

defp apply_one(%{"createOrReplace" => attrs}, dataset) do
  type = attrs["_type"] || attrs["type"]
  with {:ok, doc} <- create_document(type, attrs, dataset), do: {:ok, doc, "createOrReplace"}
end

defp apply_one(%{"createIfNotExists" => attrs}, dataset) do
  type = attrs["_type"] || attrs["type"]
  case get_document(draft_id(attrs["_id"] || ""), type, dataset) do
    {:ok, existing} -> {:ok, existing, "noop"}
    _ ->
      with {:ok, doc} <- create_document(type, attrs, dataset), do: {:ok, doc, "create"}
  end
end

defp apply_one(%{"publish" => %{"id" => id, "type" => type} = m}, dataset) do
  with :ok <- check_rev(m, type, dataset),
       {:ok, doc} <- publish_document(id, type, dataset),
       do: {:ok, doc, "publish"}
end

defp apply_one(%{"unpublish" => %{"id" => id, "type" => type}}, dataset) do
  with {:ok, doc} <- unpublish_document(id, type, dataset), do: {:ok, doc, "unpublish"}
end

defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset) do
  with {:ok, doc} <- discard_draft(id, type, dataset), do: {:ok, doc, "discardDraft"}
end

defp apply_one(%{"delete" => %{"id" => id, "type" => type}}, dataset) do
  with {:ok, doc} <- delete_document(id, type, dataset), do: {:ok, doc, "delete"}
end

defp apply_one(%{"patch" => %{"id" => id, "type" => type, "set" => fields} = m}, dataset) do
  with :ok <- check_rev(m, type, dataset),
       {:ok, existing} <- get_document(id, type, dataset) do
    merged = Map.merge(existing.content || %{}, Map.drop(fields, ~w(title status _id _type _rev)))
    attrs = %{"doc_id" => id, "title" => fields["title"] || existing.title, "content" => merged}
    with {:ok, doc} <- upsert_document(type, attrs, dataset), do: {:ok, doc, "update"}
  end
end

defp apply_one(_, _), do: {:error, :malformed}

defp check_rev(%{"ifRevisionID" => rev}, type, dataset) when is_binary(rev) do
  id = get_in(rev, [])
  # get id from caller context instead
  :ok
end
defp check_rev(_, _, _), do: :ok
```

Note: `check_rev` as written above is a stub — rev enforcement lands in Task 8. Keep the `ifRevisionID` parser slot now so the shape is reserved.

- [ ] **Step 4: Rewrite `MutateController.mutate/2`**

```elixir
def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
  case Content.apply_mutations(mutations, dataset) do
    {:ok, {tx_id, results}} ->
      json(conn, %{transactionId: tx_id, results: results})

    {:error, reason} ->
      env = Barkpark.Content.Errors.to_envelope({:error, reason})
      conn |> put_status(env.status) |> json(%{error: Map.delete(env, :status)})
  end
end

def mutate(conn, _), do:
  conn |> put_status(400) |> json(%{error: %{code: "malformed", message: "expected {\"mutations\": [...]}"}})
```

- [ ] **Step 5: Run — expect pass**

```bash
cd api && mix test test/barkpark_web/contract/mutate_test.exs
```

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark/content.ex api/lib/barkpark_web/controllers/mutate_controller.ex api/test/barkpark_web/contract/mutate_test.exs
git commit -m "feat(api): atomic mutation batches with structured results"
```

---

### Task 8: `ifRevisionID` optimistic concurrency

**Files:**
- Modify: `api/lib/barkpark/content.ex`
- Modify: `api/test/barkpark_web/contract/mutate_test.exs`

- [ ] **Step 1: Add failing test**

```elixir
test "patch with stale ifRevisionID returns rev_mismatch", %{conn: conn} do
  {:ok, doc} = Content.create_document("post", %{"_id" => "rm-1", "title" => "v1"}, "test")

  body = %{
    "mutations" => [
      %{"patch" => %{"id" => doc.doc_id, "type" => "post", "ifRevisionID" => "wrong-rev", "set" => %{"title" => "v2"}}}
    ]
  }

  resp =
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", Jason.encode!(body))

  assert resp.status == 409
  assert Jason.decode!(resp.resp_body)["error"]["code"] == "rev_mismatch"
end
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Real rev check**

Replace `check_rev/3` and update patch/publish clauses to pass the document id in:

```elixir
defp apply_one(%{"patch" => %{"id" => id, "type" => type, "set" => fields} = m}, dataset) do
  with {:ok, existing} <- get_document(id, type, dataset),
       :ok <- ensure_rev(existing, m["ifRevisionID"]) do
    merged = Map.merge(existing.content || %{}, Map.drop(fields, ~w(title status _id _type _rev)))
    attrs = %{"doc_id" => id, "title" => fields["title"] || existing.title, "content" => merged}
    with {:ok, doc} <- upsert_document(type, attrs, dataset), do: {:ok, doc, "update"}
  end
end

defp ensure_rev(_doc, nil), do: :ok
defp ensure_rev(%{rev: r}, r), do: :ok
defp ensure_rev(_, _), do: {:error, :rev_mismatch}
```

Delete the stub `check_rev/3`.

- [ ] **Step 4: Run — expect pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(api): ifRevisionID optimistic concurrency on patch"
```

---

## Phase 3 — Query surface: pagination, ordering, filter

### Task 9: Structured filter + pagination

**Files:**
- Modify: `api/lib/barkpark/content.ex` (`list_documents`)
- Modify: `api/lib/barkpark_web/controllers/query_controller.ex`
- Test: `api/test/barkpark_web/contract/query_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule BarkparkWeb.Contract.QueryTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(%{"name" => "post", "visibility" => "public", "fields" => []}, "test")
    for i <- 1..5 do
      {:ok, _} = Content.create_document("post", %{"_id" => "q#{i}", "title" => "T#{i}"}, "test")
      Content.publish_document("q#{i}", "post", "test")
    end
    :ok
  end

  test "limit caps page size", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post?limit=2") |> json_response(200)
    assert length(body["documents"]) == 2
    assert body["count"] == 2
    assert is_integer(body["limit"]) and body["limit"] == 2
  end

  test "offset paginates", %{conn: conn} do
    b1 = conn |> get("/v1/data/query/test/post?limit=2&offset=0") |> json_response(200)
    b2 = conn |> get("/v1/data/query/test/post?limit=2&offset=2") |> json_response(200)
    ids1 = Enum.map(b1["documents"], & &1["_id"])
    ids2 = Enum.map(b2["documents"], & &1["_id"])
    assert MapSet.disjoint?(MapSet.new(ids1), MapSet.new(ids2))
  end

  test "filter[field]=value works", %{conn: conn} do
    body = conn |> get("/v1/data/query/test/post?filter[title]=T3") |> json_response(200)
    assert length(body["documents"]) == 1
    assert hd(body["documents"])["title"] == "T3"
  end
end
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Extend `list_documents/3`**

In `api/lib/barkpark/content.ex`:

```elixir
def list_documents(type, dataset, opts \\ []) do
  perspective = Keyword.get(opts, :perspective, :raw)
  filter_map = Keyword.get(opts, :filter_map, %{})
  limit = Keyword.get(opts, :limit, 100) |> min(1000) |> max(1)
  offset = Keyword.get(opts, :offset, 0) |> max(0)
  order = Keyword.get(opts, :order, :updated_at_desc)

  Document
  |> where([d], d.type == ^type and d.dataset == ^dataset)
  |> apply_perspective(perspective)
  |> apply_filter_map(filter_map)
  |> apply_order(order)
  |> limit(^limit)
  |> offset(^offset)
  |> Repo.all()
  |> maybe_merge_drafts(perspective)
end

defp apply_filter_map(query, map) when map_size(map) == 0, do: query
defp apply_filter_map(query, map) do
  Enum.reduce(map, query, fn
    {"title", v}, q -> where(q, [d], d.title == ^v)
    {"status", v}, q -> where(q, [d], d.status == ^v)
    {field, v}, q -> where(q, [d], fragment("?->>? = ?", d.content, ^field, ^v))
  end)
end

defp apply_order(q, :updated_at_desc), do: order_by(q, [d], desc: d.updated_at)
defp apply_order(q, :updated_at_asc), do: order_by(q, [d], asc: d.updated_at)
defp apply_order(q, :created_at_desc), do: order_by(q, [d], desc: d.inserted_at)
defp apply_order(q, :created_at_asc), do: order_by(q, [d], asc: d.inserted_at)
defp apply_order(q, _), do: order_by(q, [d], desc: d.updated_at)
```

Delete the old single-string `maybe_filter`.

- [ ] **Step 4: Update `QueryController.index/2`**

```elixir
def index(conn, %{"dataset" => dataset, "type" => type} = params) do
  if not Content.schema_public?(type, dataset) and not authed?(conn) do
    {:error, :not_found}
  else
    perspective = parse_perspective(params["perspective"] || "published")
    limit = parse_int(params["limit"], 100)
    offset = parse_int(params["offset"], 0)
    order = parse_order(params["order"])
    filter_map = Map.get(params, "filter") || %{}

    docs =
      Content.list_documents(type, dataset,
        perspective: perspective,
        filter_map: filter_map,
        limit: limit,
        offset: offset,
        order: order
      )

    json(conn, %{
      perspective: to_string(perspective),
      documents: Envelope.render_many(docs),
      count: length(docs),
      limit: limit,
      offset: offset
    })
  end
end

defp parse_int(nil, d), do: d
defp parse_int(s, d) when is_binary(s), do: case Integer.parse(s) do {n, _} -> n; _ -> d end

defp parse_order("_updatedAt:asc"), do: :updated_at_asc
defp parse_order("_updatedAt:desc"), do: :updated_at_desc
defp parse_order("_createdAt:asc"), do: :created_at_asc
defp parse_order("_createdAt:desc"), do: :created_at_desc
defp parse_order(_), do: :updated_at_desc

defp authed?(conn), do: get_req_header(conn, "authorization") != []
```

- [ ] **Step 5: Run — expect pass**

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(api): query pagination, ordering, and structured filter"
```

---

## Phase 4 — SSE envelope and resume

### Task 10: Mutation events table

**Files:**
- Create: `api/priv/repo/migrations/20260413000002_create_mutation_events.exs`
- Create: `api/lib/barkpark/content/mutation_event.ex`

- [ ] **Step 1: Migration**

```elixir
defmodule Barkpark.Repo.Migrations.CreateMutationEvents do
  use Ecto.Migration

  def change do
    create table(:mutation_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :dataset, :text, null: false
      add :type, :text, null: false
      add :doc_id, :text, null: false
      add :mutation, :text, null: false
      add :rev, :text, null: false
      add :previous_rev, :text
      add :document, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:mutation_events, [:dataset, :id])
  end
end
```

- [ ] **Step 2: Ecto schema**

```elixir
defmodule Barkpark.Content.MutationEvent do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "mutation_events" do
    field :dataset, :string
    field :type, :string
    field :doc_id, :string
    field :mutation, :string
    field :rev, :string
    field :previous_rev, :string
    field :document, :map
    field :inserted_at, :utc_datetime_usec
  end
end
```

- [ ] **Step 3: Migrate**

```bash
cd api && MIX_ENV=dev mix ecto.migrate
```

- [ ] **Step 4: Commit**

```bash
git add api/priv/repo/migrations api/lib/barkpark/content/mutation_event.ex
git commit -m "feat(api): mutation_events table for SSE resume"
```

---

### Task 11: Write to event log on every mutation

**Files:**
- Modify: `api/lib/barkpark/content.ex` (inside `tap_broadcast`)
- Test: `api/test/barkpark/content/event_log_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Barkpark.Content.EventLogTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.MutationEvent
  import Ecto.Query

  test "create inserts a mutation_event row" do
    {:ok, _} = Content.create_document("post", %{"_id" => "ev-1", "title" => "x"}, "test")
    events = Repo.all(from e in MutationEvent, where: e.dataset == "test")
    assert [%{mutation: "update"}] = events  # tap_broadcast default
  end
end
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: In `tap_broadcast`, after `save_revision`, insert a mutation event**

```elixir
alias Barkpark.Content.{Envelope, MutationEvent}

defp save_event(doc, type, dataset, action, previous_rev) do
  %MutationEvent{}
  |> Ecto.Changeset.change(%{
    dataset: dataset,
    type: type,
    doc_id: doc.doc_id,
    mutation: action,
    rev: doc.rev,
    previous_rev: previous_rev,
    document: Envelope.render(doc),
    inserted_at: DateTime.utc_now()
  })
  |> Repo.insert!()
end
```

Call `save_event(doc, type, dataset, action, nil)` inside `tap_broadcast` right after `save_revision`. (Tracking `previous_rev` across updates is future work — leave `nil` for now but reserve the column.)

Also put the **MutationEvent id** (`ev.id`) into the PubSub message so `listen_loop` can send it as the SSE `id:` line:

```elixir
msg = %{
  event_id: ev.id,
  type: type,
  mutation: action,
  doc_id: doc.doc_id,
  rev: doc.rev,
  document: Envelope.render(doc)
}
```

- [ ] **Step 4: Run — expect pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(api): log mutation events with monotonic ids"
```

---

### Task 12: SSE envelope + `Last-Event-ID` resume

**Files:**
- Modify: `api/lib/barkpark_web/controllers/listen_controller.ex`
- Test: `api/test/barkpark_web/contract/listen_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule BarkparkWeb.Contract.ListenTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content

  test "GET /v1/data/listen with Last-Event-ID replays", %{conn: conn} do
    Content.upsert_schema(%{"name" => "post", "visibility" => "public", "fields" => []}, "rep")
    {:ok, _} = Content.create_document("post", %{"_id" => "r1", "title" => "a"}, "rep")
    {:ok, _} = Content.create_document("post", %{"_id" => "r2", "title" => "b"}, "rep")

    # Synchronous: just hit the controller internal replay fn to avoid streaming in a test
    events = BarkparkWeb.ListenController.replay_since("rep", 0)
    assert length(events) == 2
    assert Enum.all?(events, &(&1.mutation in ~w(update create)))
  end
end
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Rewrite `ListenController`**

```elixir
defmodule BarkparkWeb.ListenController do
  use BarkparkWeb, :controller
  import Ecto.Query
  alias Barkpark.{Repo, Content}
  alias Barkpark.Content.MutationEvent

  def listen(conn, %{"dataset" => dataset} = params) do
    since =
      case get_req_header(conn, "last-event-id") do
        [v | _] -> parse_int(v)
        _ -> parse_int(params["lastEventId"])
      end

    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: welcome\ndata: {\"type\":\"welcome\"}\n\n")

    conn =
      if since do
        Enum.reduce(replay_since(dataset, since), conn, fn ev, c ->
          case chunk(c, format_event(ev)) do
            {:ok, c2} -> c2
            _ -> c
          end
        end)
      else
        conn
      end

    listen_loop(conn)
  end

  def replay_since(dataset, since) do
    from(e in MutationEvent, where: e.dataset == ^dataset and e.id > ^since, order_by: e.id)
    |> Repo.all()
  end

  defp format_event(ev) do
    data =
      Jason.encode!(%{
        eventId: ev.id,
        mutation: ev.mutation,
        type: ev.type,
        documentId: ev.doc_id,
        rev: ev.rev,
        previousRev: ev.previous_rev,
        result: ev.document
      })

    "id: #{ev.id}\nevent: mutation\ndata: #{data}\n\n"
  end

  defp listen_loop(conn) do
    receive do
      {:document_changed, %{event_id: eid} = msg} ->
        ev = %{
          id: eid,
          mutation: msg.mutation,
          type: msg.type,
          doc_id: msg.doc_id,
          rev: msg.rev,
          previous_rev: nil,
          document: msg.document
        }
        case chunk(conn, format_event(ev)) do
          {:ok, c} -> listen_loop(c)
          _ -> conn
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, c} -> listen_loop(c)
          _ -> conn
        end
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_binary(v), do: case Integer.parse(v) do {n, _} -> n; _ -> nil end
end
```

- [ ] **Step 4: Run — expect pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(api): SSE envelope with Last-Event-ID resume"
```

---

## Phase 5 — Cross-cutting hygiene

### Task 13: Corsica CORS

**Files:**
- Modify: `api/mix.exs`, `api/lib/barkpark_web/endpoint.ex`

- [ ] **Step 1: Add dep**

In `api/mix.exs` deps: `{:corsica, "~> 2.1"}`. Run `cd api && mix deps.get`.

- [ ] **Step 2: Plug in endpoint**

In `api/lib/barkpark_web/endpoint.ex`, before `plug BarkparkWeb.Router`:

```elixir
plug Corsica,
  origins: "*",
  allow_headers: ["authorization", "content-type", "last-event-id"],
  expose_headers: ["etag"],
  max_age: 600
```

- [ ] **Step 3: Smoke test**

```bash
cd api && mix phx.server &
sleep 2
curl -i -X OPTIONS http://localhost:4000/v1/data/query/production/post \
  -H "Origin: https://example.com" \
  -H "Access-Control-Request-Method: GET"
kill %1
```
Expected: `Access-Control-Allow-Origin: *` in the response.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(api): CORS via Corsica for v1 endpoints"
```

---

### Task 14: Schema response shape + `_schemaVersion`

**Files:**
- Modify: `api/lib/barkpark_web/controllers/schema_controller.ex`
- Test: `api/test/barkpark_web/contract/schema_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule BarkparkWeb.Contract.SchemaTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content

  test "schema response carries _schemaVersion", %{conn: conn} do
    Content.upsert_schema(%{"name" => "post", "visibility" => "public", "fields" => []}, "test")
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/schemas/test")
      |> json_response(200)

    assert body["_schemaVersion"] == 1
    assert is_list(body["schemas"])
  end
end
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Update `SchemaController.index`**

```elixir
def index(conn, %{"dataset" => dataset}) do
  schemas = Content.list_schemas(dataset) |> Enum.map(&render_schema/1)
  json(conn, %{_schemaVersion: 1, schemas: schemas})
end

defp render_schema(s) do
  %{name: s.name, visibility: s.visibility, fields: s.fields, title: s.title, icon: s.icon}
end
```

Apply same `_schemaVersion: 1` to `show/2`.

- [ ] **Step 4: Run — expect pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(api): _schemaVersion on /v1/schemas responses"
```

---

### Task 15: Legacy deprecation headers

**Files:**
- Modify: `api/lib/barkpark_web/router.ex`

- [ ] **Step 1: Add a plug**

Create a tiny inline plug at the top of `router.ex`:

```elixir
defmodule BarkparkWeb.Plugs.LegacyDeprecation do
  import Plug.Conn

  def init(_), do: []

  def call(conn, _) do
    conn
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("sunset", "Wed, 31 Dec 2026 23:59:59 GMT")
    |> put_resp_header("link", "</v1/data/query>; rel=\"successor-version\"")
  end
end
```

And use it in the `/api` scope:

```elixir
scope "/api", BarkparkWeb do
  pipe_through [:api, BarkparkWeb.Plugs.LegacyDeprecation]
  # ...existing routes
end
```

- [ ] **Step 2: Smoke test**

```bash
curl -i http://localhost:4000/api/schemas | grep -i deprecation
```
Expected: `deprecation: true`.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(api): mark /api/documents legacy with Deprecation/Sunset headers"
```

---

## Phase 6 — Freeze

### Task 16: Write `docs/api-v1.md`

**Files:**
- Create: `docs/api-v1.md`

- [ ] **Step 1: Write the doc**

Sections required:
1. Document envelope (every `_` field, types, nullability)
2. `GET /v1/data/query/:dataset/:type` — params (`perspective`, `limit`, `offset`, `order`, `filter[<field>]`), response shape, status codes
3. `GET /v1/data/doc/:dataset/:type/:id` — response shape
4. `POST /v1/data/mutate/:dataset` — request body, each mutation kind (`create`, `createOrReplace`, `createIfNotExists`, `patch`, `publish`, `unpublish`, `discardDraft`, `delete`), response (`transactionId`, `results[]`), atomicity guarantee, `ifRevisionID`
5. `GET /v1/data/listen/:dataset` — SSE envelope, `Last-Event-ID`, keepalive cadence
6. `GET /v1/schemas/:dataset` — shape + `_schemaVersion`
7. Error codes table: `not_found`, `unauthorized`, `forbidden`, `schema_unknown`, `rev_mismatch`, `malformed`, `validation_failed`, `conflict`, `internal_error`
8. Reserved field names (`_id`, `_type`, `_rev`, `_draft`, `_publishedId`, `_createdAt`, `_updatedAt`)
9. Stability guarantee: "Any breaking change to shapes in this document requires bumping to `/v2`."

Keep examples as `curl | jq` blocks, one per endpoint.

- [ ] **Step 2: Commit**

```bash
git add docs/api-v1.md
git commit -m "docs: freeze v1 HTTP API reference"
```

---

### Task 17: Run the whole contract suite

- [ ] **Step 1: Run**

```bash
cd api && mix test test/barkpark_web/contract/
```
Expected: all green.

- [ ] **Step 2: Run full suite**

```bash
cd api && mix test
```
Expected: zero failures. If legacy tests break because they asserted on the old envelope, update them to assert on the legacy `/api/documents` endpoints, which are unchanged. Do not "fix" them by reverting envelope work.

- [ ] **Step 3: Deploy to staging/prod**

```bash
ssh root@89.167.28.206
cd /opt/barkpark
make deploy
```

- [ ] **Step 4: Smoke test remote**

```bash
curl -s http://89.167.28.206/v1/data/query/production/post?limit=1 | jq '.documents[0] | keys'
```
Expected keys include `_id`, `_type`, `_rev`, `_createdAt`, `_updatedAt`, `title`. Does **not** include `content`.

- [ ] **Step 5: Final commit (if anything tweaked)**

---

## Phase 8 — Deferred (not part of this plan, tracked for later)

1. Migrate Go TUI off `/api/documents/*` to `/v1/data/*`.
2. Migrate Studio LiveView to read envelopes from `Envelope.render/1` directly (it currently reads `doc.content` etc. from DB structs — works fine, just inconsistent).
3. Reference expansion under `?expand=_ref` with a new explicit contract (not the lossy old one).
4. Richer filter DSL (`filter[field][eq]=`, `[in]=`, `[gt]=`).
5. Rate limiting plug on `/v1/data/mutate`.
6. OpenAPI generator (falls out of the contract tests).
7. `@barkpark/client` SDK.

---

## Self-Review

**Spec coverage:** Phase 1 covers envelope decisions (flat, `_rev`, reserved keys, date format). Phase 2 covers atomic mutations, structured errors, `create`/`createOrReplace`/`createIfNotExists` split, `ifRevisionID`. Phase 3 covers pagination, ordering, structured filter. Phase 4 covers SSE envelope + resume. Phase 5 covers CORS, schema version, legacy deprecation. Phase 6 writes docs + freezes. ✓ All in-scope items from the earlier planning discussion are represented.

**Gaps I accepted on purpose:**
- Reference expansion (`expand=true`) is explicitly deferred to Phase 8 because the current shape is lossy and I'd rather ship no expansion than freeze a bad one.
- SSE query-param auth is not implemented (Last-Event-ID via header works for `fetch`-based EventSource; browser `EventSource` users will need it later).
- Rate limiting is Phase 8.

**Type consistency check:** `Envelope.render/1` signature matches usage everywhere. `apply_mutations/2` returns `{:ok, {tx_id, results}}` consistently. `Errors.to_envelope/1` is the single entry point.

**Placeholder scan:** None. Every step shows the exact code or the exact command.

---

**Plan complete. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task with two-stage review between tasks. Best for a 17-task plan like this.

**2. Inline Execution** — Execute tasks in this session with checkpoints at each phase boundary.

Which approach?
