defmodule BarkparkWeb.GraphDraftsCorpusTruncationTest do
  @moduledoc """
  THE TRUNCATION THAT READ AS A BROKEN LINK (task-09889a18f174fcb2).

  `Content.Graph.build_drafts_index/1` reads the drafts corpus under a
  whole-corpus bound (`Content.Graph.corpus_limit/0`). Past that bound the read
  returns a PREFIX — and the drafts fold used the prefix's slug set as the
  membership lens for plugin-edge `dangling`. So a reference to a document that
  really exists, and merely fell past the bound, came back as a `phantom` node:
  the graph reported its OWN truncation as a phantom reference.

  That is worse than an incomplete answer. An incomplete answer says "there may
  be more"; this one said "this link is broken", which is a WRONG DIAGNOSIS a
  reader acts on — chasing a reference that was never broken.

  ## What this file pins

    * the RESPONSE carries the condition: `truncated: true`,
      `truncation_reason: "corpus_cap"`, and a `corpus_truncation` object
      naming the bound and how much was read;
    * under a cap the two conditions stay DISTINGUISHABLE: a reference to a
      real-but-unread document is NOT reported dangling (no phantom node),
      while a reference to a genuinely absent document still is;
    * BELOW the cap nothing changes: no flag, `corpus_truncation: null`, and a
      genuinely dangling reference still renders as a phantom.

  The corpus bound is lowered through `:barkpark, :graph_drafts_corpus_limit`
  (its documented TESTS-ONLY escape hatch) instead of seeding 20,001 rows.

  ## Why the edges come through the plugin seam

  A CORE reference-field edge resolves `dangling` against the `:published` DB
  lens (`resolve_core_dangling/3`), which the corpus bound never touched. The
  corpus-prefix lens was only ever applied to PLUGIN edges
  (`normalize_plugin_drafts_edge/3`), so the defect lives there and a fixture
  that did not drive the `:edge_extractor_collector` seam could not reproduce
  it. The stub below is the same one `graph_extractor_seam_test.exs` uses.

  ## Ordering is load-bearing, not incidental

  `Content.Query.collect_corpus_documents/3` orders `asc: type, asc: slug`, so
  the prefix a cap keeps is the alphabetically-first `limit` rows, TYPE first.
  The fixture therefore names its type `aa_post` (first among the dataset's
  types) and names its documents `a-…` / `m-…` / `z-…`, so the source is inside
  the prefix and the target is past it. Otherwise "unread" would be a coin flip
  decided by whatever else the dataset happens to hold.
  """

  # NOT async: both the corpus bound and the extractor seam are single global
  # `Application` env keys.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-graph-corpus-truncation"
  @dataset "production"
  @seam_key :edge_extractor_collector
  @limit_key :graph_drafts_corpus_limit

  # The cap. Small enough that four documents straddle it, large enough that
  # the SOURCE and its two fillers are comfortably inside the prefix.
  @cap 3

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@token, "graph-corpus-truncation", @dataset, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "aa_post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "related", "type" => "reference", "refType" => "aa_post"}]
        },
        @dataset,
        scope
      )

    original_seam = Application.get_env(:barkpark, @seam_key)
    original_limit = Application.get_env(:barkpark, @limit_key)

    on_exit(fn ->
      restore(@seam_key, original_seam)
      restore(@limit_key, original_limit)
    end)

    %{scope: scope}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp bearer(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  # A unique run tag keeps this module's slugs out of any other module's corpus
  # while preserving the a/m/z ordering the cap depends on.
  defp run_tag, do: "ct#{System.unique_integer([:positive])}"

  defp mk!(doc_id, scope, content \\ %{}) do
    {:ok, doc} =
      Content.create_document(
        "aa_post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp publish!(doc_id, scope) do
    {:ok, _} = Content.publish_document(doc_id, "aa_post", @dataset, scope)
  end

  # Install a plugin edge supplier through the inverted seam: `source` emits one
  # edge to each slug in `targets`. Plugin edges carry no refType, exactly like
  # a Bulldocs valueref.
  defp install_seam!(source, targets) do
    Application.put_env(:barkpark, @seam_key, fn opts ->
      baseline = Keyword.fetch!(opts, :baseline)
      ctx = Keyword.fetch!(opts, :ctx)
      slug = Content.published_id(Map.get(ctx.doc, :doc_id))

      if slug == source do
        baseline ++
          Enum.map(targets, fn t ->
            %{from_id: source, to_id: t, kind: "valueref", plugin_source: "seam_stub"}
          end)
      else
        baseline
      end
    end)
  end

  defp graph(conn, root) do
    resp = conn |> bearer() |> get("/v1/graph/#{root}?drafts=true")
    assert resp.status == 200, resp.resp_body
    {Jason.decode!(resp.resp_body), resp.resp_body}
  end

  defp phantom_ids(body) do
    for n <- body["nodes"], n["phantom"] == true, do: n["broken_id"]
  end

  defp node_ids(body) do
    for n <- body["nodes"], n["phantom"] != true, do: n["doc_id"]
  end

  describe "a drafts corpus larger than the bound" do
    test "the response says it truncated, and an unread target is not a phantom",
         %{conn: conn, scope: scope} do
      tag = run_tag()
      source = "a-#{tag}-source"
      # Past the cap by name: the read keeps `a-…` and the two `m-…` fillers.
      unread = "z-#{tag}-unread-but-real"
      absent = "z-#{tag}-never-existed"

      mk!(source, scope)
      publish!(source, scope)
      for i <- 1..2, do: mk!("m-#{tag}-filler-#{i}", scope)

      # REAL, and PUBLISHED — so the only thing making it look broken is that
      # the corpus read never reached it.
      mk!(unread, scope)
      publish!(unread, scope)

      install_seam!(source, [unread, absent])
      Application.put_env(:barkpark, @limit_key, @cap)

      {body, raw} = graph(conn, source)

      assert body["truncated"] == true,
             "the drafts corpus read capped at #{@cap} and the response did not say so — a " <>
               "consumer cannot tell this graph is a PREFIX: #{raw}"

      assert body["truncation_reason"] == "corpus_cap",
             "the corpus bound must name itself, not borrow a BFS bound's reason: #{raw}"

      assert body["corpus_truncation"] == %{
               "truncated" => true,
               "limit" => @cap,
               "read" => @cap
             },
             "corpus_truncation must state the bound and what was read: #{raw}"

      # THE DISCRIMINATOR, direction 1: a real document past the bound is not a
      # broken reference.
      refute unread in phantom_ids(body),
             "`#{unread}` EXISTS and is published — it was merely past the corpus bound, and " <>
               "the graph reported it as a phantom reference. That is the truncation being " <>
               "diagnosed as a broken link: #{raw}"

      assert unread in node_ids(body),
             "an unread-but-real target must resolve as a real node once the read admits it " <>
               "could not see the whole corpus: #{raw}"

      # THE DISCRIMINATOR, direction 2: a genuinely absent target is STILL a
      # phantom, so the flag did not simply suppress every dangling verdict.
      assert absent in phantom_ids(body),
             "`#{absent}` does not exist anywhere; a truncated read must still report it as a " <>
               "phantom, or the fix traded one wrong diagnosis for another: #{raw}"
    end
  end

  describe "a drafts corpus smaller than the bound (control)" do
    test "no flag, and a genuinely dangling edge is still dangling",
         %{conn: conn, scope: scope} do
      tag = run_tag()
      source = "a-#{tag}-ctl-source"
      present = "m-#{tag}-ctl-present"
      absent = "z-#{tag}-ctl-never-existed"

      mk!(source, scope)
      publish!(source, scope)
      mk!(present, scope)
      publish!(present, scope)

      install_seam!(source, [present, absent])
      # Well above the fixture — the corpus is read WHOLE.
      Application.put_env(:barkpark, @limit_key, 5_000)

      {body, raw} = graph(conn, source)

      assert body["truncated"] == false,
             "the whole corpus was read; nothing may claim truncation: #{raw}"

      assert body["truncation_reason"] == nil, raw

      assert body["corpus_truncation"] == nil,
             "a complete read must report `corpus_truncation: null`, not an empty object or a " <>
               "stale flag: #{raw}"

      assert present in node_ids(body),
             "a target inside the corpus is a real node: #{raw}"

      assert absent in phantom_ids(body),
             "with the WHOLE corpus read, a target absent from it is genuinely dangling and " <>
               "must still be reported as a phantom — the two conditions have to stay " <>
               "distinguishable in BOTH directions: #{raw}"

      refute present in phantom_ids(body), raw
    end
  end
end
