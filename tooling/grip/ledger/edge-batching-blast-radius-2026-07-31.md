# edge-batching-blast-radius — callers of add_edge/add_edges and the indexes Lever 1 assumes

Verified against `origin/main` = `e3403110465e094d8ff06f4cc68c2c3ee342dfdd` on
2026-07-31. Every line is a re-derivation recipe, not a conclusion.

## FIRST FINDING: the brief's own grep is broken and returns a FALSE EMPTY

    git grep -n 'add_edge(\|add_edges(' origin/main -- api/lib | grep -v edge_projector
    # -> (no output)

git grep's default regex does NOT honour the GNU-BRE `\|` alternation, so the
pattern is matched literally and nothing hits. Anyone who ran that command and
concluded "no callers outside the projector" was reading a tooling artifact.
The honest form needs `-E`:

    git grep -nE 'add_edges?\(' origin/main -- api/lib | grep -v edge_projector
    git grep -nE '(Content|Edges)\.add_edges?\(' origin/main | grep -v edge_projector

## Production callers outside the projector: exactly ONE

    git grep -nE '(Content|Edges)\.add_edges?\(' origin/main -- api/lib | grep -v edge_projector
    # -> api/lib/barkpark/content.ex:291    (facade delegation, not a caller)
    # -> api/lib/barkpark/content.ex:296    (facade delegation, not a caller)
    # -> api/lib/barkpark/content/papers/proposals.ex:216

`tasks_controller.ex:1242 def add_edge` is the TASK-edge HTTP action, a name
collision — it does not call Content/Edges.add_edge.

## Does that caller consume the re-read %Edge{}? YES — one field, `.kind`

    git show origin/main:api/lib/barkpark/content/papers/proposals.ex | sed -n '216,220p;120p;125,128p'
    #   case Edges.add_edge(draft.id, source["doc_id"], @edge_kind, attrs) do
    #     {:ok, edge} -> edge
    #   ...
    #   edge = add_provenance_edge(draft, pub, source, dataset)
    #   provenance: %{from: draft.doc_id, to: source["doc_id"], kind: edge.kind}

`.kind` is the ONLY field read, and it is `@edge_kind` — known at the call site.
So dropping `fetch_content_edge!` costs this caller nothing provided the
returned struct still carries `kind` (the pre-insert changeset already does).

## The re-read (`fetch_content_edge!`) and what pins it

    git show origin/main:api/lib/barkpark/content/edges.ex | sed -n '451p'
    #   {:ok, fetch_content_edge!(from_pk, to_pk, to_string(kind))}
    git show origin/main:api/lib/barkpark/content/edges.ex | sed -n '644,650p'
    #   defp fetch_content_edge!(from_id, to_id, kind) do
    #     Repo.one!(from(e in Barkpark.Content.Edge, where: ...))

Tests that assert on the RETURNED struct (these change if the re-read is dropped
and Ecto's `insert` return is used instead — Ecto returns the SUBMITTED struct on
`on_conflict: {:replace, …}`, whose `id` is the newly generated one, NOT the
surviving row's):

    git show origin/main:api/test/barkpark/content/edge_extract_test.exs | sed -n '287,308p'
    #   [{:ok, e1}] = Content.add_edges(first, dataset: @dataset)
    #   assert e1.weight == 1.0
    #   [{:ok, e2}] = Content.add_edges(second, dataset: @dataset)
    #   assert e2.id == e1.id, "same triple -> same row (idempotent on the triple)"
    #   assert e2.weight == 2.0

`assert e2.id == e1.id` is the load-bearing pin: it is TRUE ONLY because of the
re-read. This is the test a batching lever must confront.

Other test call sites bind `{:ok, _}` / `{:ok, _edge}` and read nothing:

    git grep -nE 'Content\.add_edge\(' origin/main -- api/test
    # -> content_find_referencing_docs_test.exs:165, modal_a11y_test.exs:64,
    #    studio_live_delete_modal_test.exs:70, studio_live_unpublish_guard_test.exs:103

## Index 1 — content_edges "from_id" for delete_outbound_for: EXISTS as a prefix

The query (projector.ex:206-212) is `where e.from_id in ^pks` — from_id only,
no kind:

    git show origin/main:api/lib/barkpark/edge_projector/projector.ex | sed -n '206,213p'

There is NO standalone `(from_id)` index; there is a leading-column one, which
Postgres uses for a from_id-only predicate:

    git show origin/main:api/priv/repo/migrations/20260614230000_create_content_edges.exs | sed -n '94,102p'
    #   create unique_index(:content_edges, [:from_id, :to_id, :kind],
    #            name: :content_edges_from_to_kind_uniq
    #          )
    #   create index(:content_edges, [:from_id, :kind])
    #   create index(:content_edges, [:to_id, :kind])

`20260614230000_create_content_edges.exs` is the ONLY migration touching
content_edges:

    git grep -lnE 'index\(:content_edges' origin/main -- api/priv/repo/migrations

## Index 2 — documents(doc_id, dataset) for resolve_doc_pk: DOES NOT EXIST

resolve_doc_pk's predicate is `doc_id == pub or doc_id == draft or id == ^id`,
plus WriteScope dataset scoping — and NO `type`:

    git show origin/main:api/lib/barkpark/content/edges.ex | sed -n '470,485p'
    git show origin/main:api/lib/barkpark/content/write_scope.ex | sed -n '/def scope_to_dataset/,/^  end/p'
    #   where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

Every documents index on main:

    git grep -nE 'index\(:documents' origin/main -- api/priv/repo/migrations
    # 20260412090737_create_initial_tables.exs:18  unique (doc_id, type, dataset)   <- DROPPED later
    # 20260412090737_create_initial_tables.exs:19  (type, dataset)
    # 20260412090737_create_initial_tables.exs:20  (status)
    # 20260413000001_add_rev_to_documents.exs:11   (rev)
    # 20260527134000_flip_uniqueness_to_dataset_id.exs:52  unique (doc_id, type, dataset_id)
    # 20260527134000_flip_uniqueness_to_dataset_id.exs:56  drop unique (doc_id, type, dataset)
    # 20260527141000:54  (workspace_id, project_id, type, dataset_id)
    # 20260527142000:38  (type, dataset) WHERE dataset_id IS NULL
    # 20260629150300:18  (owner_id)

Lines 154/158 of the flip migration are inside `down/0` — they do not exist on a
migrated database. Confirm:

    git show origin/main:api/priv/repo/migrations/20260527134000_flip_uniqueness_to_dataset_id.exs | sed -n '148,162p'

So the ONLY doc_id-rooted index on main is
`documents_doc_id_type_dataset_id_index = (doc_id, type, dataset_id)`. The
lever's assumed `(doc_id, dataset)` index is not there. `type` is the SECOND
column and the resolve query never constrains it, so the index is usable on the
`doc_id` leading column only; `dataset_id`/`dataset` is a heap recheck, not an
index condition. There is no `priv/repo/structure.sql` — migrations are the only
schema source of truth in the tree:

    git ls-tree origin/main api/priv/repo/ --name-only
