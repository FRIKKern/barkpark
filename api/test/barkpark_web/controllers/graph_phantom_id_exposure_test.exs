defmodule BarkparkWeb.GraphPhantomIdExposureTest do
  @moduledoc """
  THE MEASUREMENT behind `dr-bl-graph-phantom-id-exposure` (2026-09-06).

  `/v1/graph` (`TasksController.graph_corpus/2`) emits a PHANTOM node for every
  reference target that is absent from the published, schema-visible corpus, and
  a phantom carries the target id AS ITS TITLE. `/v1/graph` is one of the three
  routes `Plugs.PublicRead.allowed_route?/1` admits, so a public-read token reads
  those phantoms. The route was shipped on an ARGUMENT — "a public document's
  reference field already exposes the same id through the allowed
  `GET /v1/data/doc` route, so nothing new leaks" — recorded in the
  `visible_schemas/2` comment in `tasks_controller.ex`. An argument is not a
  measurement. This file is the measurement.

  For each field shape the filing names it asks TWO questions of the SAME
  public-read token, against a private-type (and, for the array shape, a
  draft-only) target:

      1. does `GET /v1/data/doc/<ds>/post/<id>` return the target id in its body?
      2. does `GET /v1/graph` emit a phantom node carrying that same id?

  A shape where (2) is true and (1) is false is a NEW leak and would bite C1.
  Every response body measured is printed by `IO.puts` so the numbers in the PR
  body are the ones the suite produced, not ones a reader has to trust.

  ## What was measured (2026-09-06, this file, on origin/main db9f9aa8a)

  | shape                  | id via /v1/data/doc | phantom in /v1/graph | verdict |
  |------------------------|---------------------|----------------------|---------|
  | `reference`            | YES                 | YES                  | no new leak |
  | `arrayOf` of reference | YES                 | YES                  | no new leak |
  | PortableDoc inline ref | YES                 | **NO**               | no leak — the graph never sees it |

  The PortableDoc row is the one the filing did not predict, and it closes the
  question from the other side: `Content.Edges.extract_field_edges/2` has exactly
  TWO clauses — `%{"type" => "reference"}` and `%{"type" => "arrayOf", "of" =>
  %{"type" => "reference"}}` — plus a `_` catch-all returning `[]`. A PortableDoc
  body carrying an inline reference produces NO edge, therefore NO phantom. So
  the third shape cannot leak an id through `/v1/graph` at all, whatever
  `/v1/data/doc` does with it.

  RULING: no shape emits a phantom whose id the same caller cannot already read
  through `GET /v1/data/doc`. `/v1/graph` phantoms are NOT a new public-read id
  leak, and C1 (drop or hash phantoms for the restricted tier) is VACUOUS.

  ## Why these tests do not rot into a tautology

  The assertions are stated as the RELATIONSHIP, not as a fixed pair of booleans:
  each shape asserts `phantom_emitted -> id_readable_via_doc_route`. Tighten the
  doc route later (redact reference values from the public-read tier, say) while
  leaving the phantom in place and these arms RED — which is exactly the signal
  the ruling depends on. Every arm also carries a NON-VACUITY assertion (the
  fixture really is a phantom-producing, invisible-to-the-corpus target) so a
  seed that silently stopped reaching the branch reds instead of passing.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  import Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    # NON-Default workspace: the corpus read scopes on the token's workspace, so
    # a Default-scoped fixture would measure a corpus every other async case is
    # also writing into.
    ws = create_workspace!("gpix-ws")
    proj = create_project!(ws, "gpix-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # PUBLIC type — what the public-read tier is allowed to read. Its three
    # fields are the three shapes under measurement.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "ref", "type" => "reference", "refType" => "ledger"},
            %{
              "name" => "refs",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "ledger"}
            },
            # A PortableDoc body. Any unknown type-tag parses as a permissive v1
            # leaf (SchemaDefinition.parse_field_type/3 catch-all), which is what
            # a real PortableDoc field is on the wire.
            %{"name" => "body", "type" => "portableDoc"}
          ]
        },
        @dataset,
        scope
      )

    # PRIVATE type — the target class whose ids the filing worried about. Never
    # in the public-read corpus (visible_schemas/2 drops it), so any reference
    # into it produces a phantom.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "ledger", "title" => "Ledger", "visibility" => "private", "fields" => []},
        @dataset,
        scope
      )

    public_read = mint!("gpix-public-read", ["public-read"], ws.id)
    admin = mint!("gpix-admin", ["read", "write", "admin"], ws.id)

    %{scope: scope, ws: ws, proj: proj, public_read: public_read, admin: admin}
  end

  defp mint!(label, perms, ws_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, perms, ws_id)
    raw
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A PUBLISHED document of the PRIVATE type — present in the database, absent
  # from the public-read corpus.
  defp mk_private_target!(scope) do
    doc_id = uniq("gpix-ledger")

    {:ok, _} =
      Content.create_document(
        "ledger",
        %{"doc_id" => doc_id, "title" => "LEDGER-TITLE-#{doc_id}", "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "ledger", @dataset, scope)
    doc_id
  end

  # A DRAFT-ONLY document of the PRIVATE type — created, never published. The
  # second way a target lands outside the corpus.
  defp mk_unpublished_target!(scope) do
    doc_id = uniq("gpix-unpub")

    {:ok, _} =
      Content.create_document(
        "ledger",
        %{"doc_id" => doc_id, "title" => "UNPUB-TITLE-#{doc_id}", "content" => %{}},
        @dataset,
        scope
      )

    doc_id
  end

  # A PUBLISHED document of the PUBLIC type, carrying `content`.
  defp mk_public_post!(content, scope) do
    doc_id = uniq("gpix-post")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "POST-#{doc_id}", "content" => content},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc_id
  end

  # ── the two probes ────────────────────────────────────────────────────────

  # (1) the ALLOWED doc route. Returns {status, raw body}.
  defp doc_probe(conn, token, doc_id) do
    resp = conn |> bearer(token) |> get("/v1/data/doc/#{@dataset}/post/#{doc_id}")
    {resp.status, resp.resp_body}
  end

  # (2) the corpus graph. Returns {status, decoded body}.
  defp graph_probe(conn, token) do
    resp = conn |> bearer(token) |> get("/v1/graph")
    {resp.status, Jason.decode!(resp.resp_body)}
  end

  defp phantom_ids(%{"nodes" => nodes}) do
    nodes
    |> Enum.filter(& &1["phantom"])
    |> Enum.map(& &1["id"])
  end

  defp real_ids(%{"nodes" => nodes}) do
    nodes
    |> Enum.reject(& &1["phantom"])
    |> Enum.map(& &1["id"])
  end

  defp report(shape, doc_body, graph_body, target) do
    IO.puts("""

    ── MEASUREMENT: #{shape} ───────────────────────────────────────────────
    target id             : #{target}
    GET /v1/data/doc body : #{doc_body}
    id present in doc body: #{doc_body =~ target}
    /v1/graph phantom ids : #{inspect(phantom_ids(graph_body))}
    phantom for target    : #{target in phantom_ids(graph_body)}
    ────────────────────────────────────────────────────────────────────────
    """)
  end

  describe "SHAPE 1 — a scalar `reference` field" do
    test "the phantom id is already readable through GET /v1/data/doc", ctx do
      %{conn: conn, scope: scope, public_read: token} = ctx

      target = mk_private_target!(scope)
      post_id = mk_public_post!(%{"ref" => target}, scope)

      {doc_status, doc_body} = doc_probe(conn, token, post_id)
      {graph_status, graph_body} = graph_probe(conn, token)

      report("reference", doc_body, graph_body, target)

      assert doc_status == 200,
             "the public-read tier must READ the public post (got #{doc_status}) — " <>
               "without a 200 this arm measures nothing: #{doc_body}"

      assert graph_status == 200,
             "the public-read tier must reach /v1/graph (got #{graph_status}) — " <>
               "PublicRead.allowed_route?/1 admits the exact two-segment path"

      # NON-VACUITY: the target really is outside the corpus, so a phantom is
      # the only node it can produce.
      refute target in real_ids(graph_body),
             "the private-type target appeared as a REAL node — visible_schemas/2 " <>
               "did not drop it and this fixture measures the wrong branch"

      phantom? = target in phantom_ids(graph_body)

      assert phantom?,
             "no phantom for a reference into a private type — the fixture never " <>
               "reached graph_corpus's phantom pass, so the arm is vacuous. " <>
               "phantoms=#{inspect(phantom_ids(graph_body))}"

      # THE RELATIONSHIP. Phantom emitted => the same caller could already read
      # the id on the allowed doc route.
      assert doc_body =~ target,
             "NEW LEAK on the `reference` shape: /v1/graph emits a phantom carrying " <>
               "#{target}, but GET /v1/data/doc does NOT return that id to the same " <>
               "public-read caller. C1 bites. doc body: #{doc_body}"
    end
  end

  describe "SHAPE 2 — an `arrayOf` of `reference` field" do
    test "the phantom ids are already readable through GET /v1/data/doc", ctx do
      %{conn: conn, scope: scope, public_read: token} = ctx

      # BOTH ways a target leaves the corpus, in one array: a published doc of a
      # private type, and a draft-only doc.
      private_target = mk_private_target!(scope)
      unpublished_target = mk_unpublished_target!(scope)

      post_id =
        mk_public_post!(%{"refs" => [private_target, unpublished_target]}, scope)

      {doc_status, doc_body} = doc_probe(conn, token, post_id)
      {graph_status, graph_body} = graph_probe(conn, token)

      report("arrayOf-of-reference", doc_body, graph_body, private_target)

      report(
        "arrayOf-of-reference (unpublished target)",
        doc_body,
        graph_body,
        unpublished_target
      )

      assert doc_status == 200, "public-read read of the public post: #{doc_body}"
      assert graph_status == 200

      for target <- [private_target, unpublished_target] do
        refute target in real_ids(graph_body),
               "#{target} appeared as a REAL node — wrong branch"

        assert target in phantom_ids(graph_body),
               "no phantom for array element #{target} — the arm is vacuous. " <>
                 "phantoms=#{inspect(phantom_ids(graph_body))}"

        assert doc_body =~ target,
               "NEW LEAK on the `arrayOf`-of-`reference` shape: /v1/graph emits a " <>
                 "phantom carrying #{target}, but GET /v1/data/doc does NOT return " <>
                 "that id to the same public-read caller. C1 bites. body: #{doc_body}"
      end
    end
  end

  describe "SHAPE 3 — a PortableDoc body carrying an inline reference" do
    test "no edge, therefore no phantom — the graph never sees an inline ref", ctx do
      %{conn: conn, scope: scope, public_read: token} = ctx

      target = mk_private_target!(scope)

      body_doc = %{
        "type" => "portableDoc",
        "blocks" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "value" => "see "},
              %{"type" => "reference", "refType" => "ledger", "id" => target}
            ]
          }
        ]
      }

      post_id = mk_public_post!(%{"body" => body_doc}, scope)

      {doc_status, doc_body} = doc_probe(conn, token, post_id)
      {graph_status, graph_body} = graph_probe(conn, token)

      report("portableDoc inline ref", doc_body, graph_body, target)

      assert doc_status == 200, "public-read read of the public post: #{doc_body}"
      assert graph_status == 200

      # THE FINDING the filing did not predict: `Content.Edges.extract_field_edges/2`
      # has no PortableDoc clause, so an inline ref produces no edge and no
      # phantom. The graph cannot leak what it never extracts.
      refute target in phantom_ids(graph_body),
             "a PortableDoc inline ref DID produce a phantom — extract_field_edges/2 " <>
               "grew a PortableDoc clause and this measurement is stale. " <>
               "phantoms=#{inspect(phantom_ids(graph_body))}"

      refute target in real_ids(graph_body),
             "the private-type target appeared as a REAL node — wrong branch"

      # And the doc route returns it anyway, so even a future PortableDoc edge
      # extractor would not be adding a new exposure.
      assert doc_body =~ target,
             "the inline ref id is NOT returned by GET /v1/data/doc — if " <>
               "extract_field_edges/2 ever grows a PortableDoc clause, that phantom " <>
               "WOULD be a new leak. body: #{doc_body}"
    end
  end

  describe "the CONTROL — the clamp itself still holds" do
    # Without this, a green file above could mean "the public-read tier sees
    # everything", which would make the ruling meaningless.
    test "a private-type document is NOT a real node, and its TITLE never appears", ctx do
      %{conn: conn, scope: scope, public_read: token, admin: admin} = ctx

      target = mk_private_target!(scope)
      _post_id = mk_public_post!(%{"ref" => target}, scope)

      {200, public_graph} = graph_probe(conn, token)
      {200, admin_graph} = graph_probe(conn, admin)

      assert target in real_ids(admin_graph),
             "the admin control does not see the private-type node either — the seed " <>
               "is invisible to EVERYONE and the clamp assertion below is vacuous"

      refute target in real_ids(public_graph),
             "a private-type document is a REAL node for the public-read tier"

      refute Jason.encode!(public_graph) =~ "LEDGER-TITLE-#{target}",
             "the private document's TITLE leaked into the public-read corpus — " <>
               "a phantom must carry the id as its title, never the real title"
    end
  end
end
