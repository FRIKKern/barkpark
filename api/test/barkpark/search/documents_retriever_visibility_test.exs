defmodule Barkpark.Search.DocumentsRetrieverVisibilityTest do
  @moduledoc """
  Schema-visibility gate on the search read path (search-template W10 / D62).

  THE LEAK (live-reproduced on guerrilla): anonymous
  `GET /v1/data/search/production?type=session` returned HTTP 200 with FULL
  private-visibility session documents — cwd, machine name, git_head — while
  `GET /v1/data/query/production/session` 404s the SAME caller. The retriever
  enforced visibility NOWHERE; the Indx indexer had the guard, the default
  Postgres retriever never did.

  THE SEAL: one clause on `DocumentsRetriever.search/4`'s `base`, immediately
  after `maybe_scope_to_grants` — results, count AND facets all derive from
  `base`, so one WHERE seals every consumer (flat/scoped HTTP, federated, the
  WS channel, loopback, and the recovery retries) at once. Predicate is an
  ALLOWLIST of PUBLIC schema names:

    * anonymous / nil caller_context → only types whose schema row declares
      `visibility: "public"`; a SCHEMALESS type is excluded too (matching the
      query route's live 404 for it) and an empty allowlist yields an EMPTY
      result (fail closed);
    * any authenticated principal (`:api_token` — including a public-read
      token — or `:user`) BYPASSES the filter: EXACT parity with
      `query_controller.ex`'s `preview? or authed? or schema_public?` gate,
      never stricter on one route (tightening for public-read tokens must move
      both routes together and is filed separately);
    * FACETS ARE NOT OPTIONAL: pre-fix, anonymous browse returned count=3879
      with facets naming `session 3 · document 4 · …` — a working existence
      DIRECTORY. The tests assert documents AND count AND facets.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext

  @ds "retriever-visibility-test"

  defp setup_scope do
    ws = create_workspace!()
    proj = create_project!(ws)
    [workspace_id: ws.id, project_id: proj.id]
  end

  defp seed_schema!(type, visibility, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => visibility},
        @ds,
        scope
      )
  end

  defp publish!(type, id, title, scope) do
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => title}, @ds, scope)
    {:ok, _} = Content.publish_document(id, type, @ds, scope)
    id
  end

  # The live leak's shape: a public "post" corpus next to a private "session"
  # corpus (published — the leak was visibility, not perspective).
  defp mixed_corpus! do
    scope = setup_scope()
    seed_schema!("post", "public", scope)
    seed_schema!("session", "private", scope)

    post_id = publish!("post", "pub-post", "Alphagrid public post", scope)
    session_id = publish!("session", "leak-session", "Alphagrid private session", scope)
    {scope, post_id, session_id}
  end

  # ── anonymous: documents AND count AND facets ───────────────────────────────

  test "anonymous browse: private type absent from documents AND count AND type facets" do
    {scope, post_id, session_id} = mixed_corpus!()

    # Browse (empty query) — the exact call that live-leaked as an existence
    # directory. NO caller_context: anonymous.
    {hits, count, meta} = Content.search_documents("", @ds, scope)

    ids = Enum.map(hits, & &1.doc_id)
    assert post_id in ids
    refute session_id in ids, "private-type doc leaked into documents"

    # COUNT covers only the public corpus — not "public hits, total-set count".
    assert count == 1

    # FACETS: the type dimension must not name the private type at all. A
    # documents-only filter would leave `session` here as an existence oracle.
    type_facet_labels =
      meta.facets
      |> Map.get("type", [])
      |> Enum.map(& &1["label"])

    assert "post" in type_facet_labels
    refute "session" in type_facet_labels, "private type leaked via the type facet"
  end

  test "anonymous ?type=session (the live repro) returns empty, not private bodies" do
    {scope, _post_id, session_id} = mixed_corpus!()

    {hits, count, _meta} = Content.search_documents("", @ds, [type: "session"] ++ scope)

    assert hits == []
    assert count == 0
    refute session_id in Enum.map(hits, & &1.doc_id)
  end

  test "anonymous keyword query cannot match a private-type doc" do
    {scope, post_id, session_id} = mixed_corpus!()

    # Both docs match "alphagrid"; only the public one may return.
    {hits, count, _meta} = Content.search_documents("alphagrid", @ds, scope)

    ids = Enum.map(hits, & &1.doc_id)
    assert post_id in ids
    refute session_id in ids
    assert count == 1
  end

  # ── allowlist, not denylist ─────────────────────────────────────────────────

  test "a SCHEMALESS type is excluded for anonymous callers (allowlist admits, never fails open)" do
    scope = setup_scope()
    seed_schema!("post", "public", scope)
    post_id = publish!("post", "al-post", "Nocturne public", scope)
    # NO schema row at all for "orphan" — the query route 404s it; a denylist
    # (`visibility != "private"`) would have admitted it.
    orphan_id = publish!("orphan", "al-orphan", "Nocturne orphan", scope)

    {hits, count, meta} = Content.search_documents("", @ds, scope)

    ids = Enum.map(hits, & &1.doc_id)
    assert post_id in ids
    refute orphan_id in ids
    assert count == 1
    refute "orphan" in (meta.facets |> Map.get("type", []) |> Enum.map(& &1["label"]))
  end

  test "empty allowlist (no public schema at all) yields EMPTY results/count/facets — fail closed" do
    scope = setup_scope()
    seed_schema!("session", "private", scope)
    publish!("session", "only-private", "Lone private session", scope)

    {hits, count, meta} = Content.search_documents("", @ds, scope)

    assert hits == []
    assert count == 0
    assert Map.get(meta.facets, "type", []) == []
  end

  # ── authed bypass: EXACT parity with the query route ───────────────────────

  test "an api_token caller — including a bare public-read token — still reads private types" do
    {scope, post_id, session_id} = mixed_corpus!()

    # The query route's `authed?` admits ANY token, public-read included
    # (query_controller.ex) — the search filter must not be silently stricter
    # on one route. Tightening this moves BOTH routes together, filed separately.
    public_read_ctx =
      CallerContext.from_token(%{id: Ecto.UUID.generate(), permissions: ["public-read"]})

    {hits, count, meta} =
      Content.search_documents("", @ds, [caller_context: public_read_ctx] ++ scope)

    ids = Enum.map(hits, & &1.doc_id)
    assert post_id in ids
    assert session_id in ids
    assert count == 2

    assert "session" in (meta.facets |> Map.get("type", []) |> Enum.map(& &1["label"]))
  end

  test "a user-session caller still reads private types" do
    {scope, _post_id, session_id} = mixed_corpus!()

    user_ctx = CallerContext.from_user(Ecto.UUID.generate(), load_grants: false)

    {hits, count, _meta} =
      Content.search_documents("", @ds, [caller_context: user_ctx] ++ scope)

    assert session_id in Enum.map(hits, & &1.doc_id)
    assert count == 2
  end

  # ── fail-broken proof ──────────────────────────────────────────────────────

  test "a public type still returns rows for anonymous callers (the live demo cannot be zeroed)" do
    scope = setup_scope()
    # ("article", not "paper": the paper type carries a publish-time authoring
    # wall — description + weighted tags — orthogonal to visibility.)
    seed_schema!("article", "public", scope)
    paper_id = publish!("article", "demo-article", "Flagship demo article", scope)

    {hits, count, _meta} = Content.search_documents("flagship", @ds, scope)

    assert paper_id in Enum.map(hits, & &1.doc_id)
    assert count >= 1
  end

  # ── recovery retries ride the same clause ──────────────────────────────────

  test "zero-hit drop_tokens recovery cannot resurrect a private-type doc" do
    {scope, _post_id, session_id} = mixed_corpus!()

    # A two-token query where only the private doc could ever match after the
    # recovery drops the noise token — the retry reuses retriever_opts, so the
    # same clause applies.
    {hits, _count, meta} =
      Content.search_documents("alphagrid session zzznomatch", @ds, scope)

    refute session_id in Enum.map(hits, & &1.doc_id)
    # Whatever the recovery did, no private hit came back.
    assert is_map(meta)
  end
end
