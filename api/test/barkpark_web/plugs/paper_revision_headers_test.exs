defmodule BarkparkWeb.Plugs.PaperRevisionHeadersTest do
  @moduledoc """
  Pins for the reader conditional (http-edge-truth W1 S1 — charter D9/D10/D11):
  a weak, time-bucketed ETag on EVERY published paper, honored with a CSP-free
  304 on both flat reader routes (`/papers/:slug` and `/d/:dataset/papers/:slug`).

  The router-level tests drive the real `:public_root` pipeline (browser →
  PaperReaderCsp → PaperRevisionHeaders → LiveView dead render), so the 304
  pins prove the halt fires BEFORE the dead render and the CSP delete undoes
  the nonce the CSP plug just minted. The direct-call tests pin the plug's
  fail-closed self-gating without a render in the way.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, EpicFleet, Repo}
  alias Barkpark.Content.{Document, Revision}
  alias BarkparkWeb.Plugs.PaperRevisionHeaders

  import Barkpark.TenancyFixtures

  @dataset "production"
  @bucket_seconds 604_800

  setup %{conn: conn} = ctx do
    {default_ws, default_project} = ensure_default_scope!()

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "conditional-paper",
          "dataset" => @dataset,
          "body_html" => "<h1>Conditional Paper</h1><p>edge truth</p>",
          "workspace_id" => default_ws.id,
          "project_id" => default_project.id
        })
      )

    paper = pin_released_revision!(paper)

    {:ok, Map.merge(ctx, %{conn: conn, ws: default_ws, project: default_project, paper: paper})}
  end

  defp stored_content(paper), do: Repo.get!(Document, paper.id).content

  defp current_bucket, do: div(System.os_time(:second), @bucket_seconds)
  defp build_digest, do: EpicFleet.canonical_digest(Barkpark.BuildInfo.info())

  defp weak_etag(content),
    do:
      ~s(W/"sha256:#{EpicFleet.canonical_digest(content)}.#{build_digest()}.#{current_bucket()}")

  defp replay(path, if_none_match) do
    scoped_conn()
    |> put_req_header("if-none-match", if_none_match)
    |> get(path)
  end

  describe "flat /papers/:slug — emit + honor (D9/D10)" do
    test "200 emits the weak bucketed etag; exact replay is a CSP-free 304 carrying the same etag + cache-control",
         %{conn: conn, paper: paper} do
      conn200 = get(conn, "/papers/conditional-paper")

      assert html_response(conn200, 200) =~ "Conditional Paper"
      assert [etag] = get_resp_header(conn200, "etag")
      assert etag == weak_etag(stored_content(paper))
      # The 200 still carries the full nonced reader policy (layer-2 backstop).
      assert [policy] = get_resp_header(conn200, "content-security-policy")
      assert policy =~ "'nonce-"

      conn304 = replay("/papers/conditional-paper", etag)

      assert conn304.status == 304
      assert conn304.resp_body == ""
      # RFC 9110 §15.4.5: the 304 re-emits the SAME validator + cache-control
      # (RFC 9111 §3.2 merge semantics — see the second-review ledger row).
      assert get_resp_header(conn304, "etag") == [etag]

      # Second-review condition 2: pin the LITERAL policy on both sides — the
      # old same-as-200 comparison was [] == [], vacuously green.
      assert get_resp_header(conn200, "cache-control") ==
               ["private, max-age=0, must-revalidate"]

      assert get_resp_header(conn304, "cache-control") ==
               ["private, max-age=0, must-revalidate"]

      # D10: a 304 carrying a fresh nonce would permanently kill the cached
      # reader in every conforming browser — the 304 branch DELETES the policy.
      assert get_resp_header(conn304, "content-security-policy") == []
    end

    test "a published paper with NO released revision still emits + honors the etag (rrid gate dropped)",
         %{conn: conn, ws: ws, project: project} do
      {:ok, unpinned} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "unpinned-paper",
            "dataset" => @dataset,
            "body_html" => "<h1>Unpinned Paper</h1>",
            "workspace_id" => ws.id,
            "project_id" => project.id
          })
        )

      conn200 = get(conn, "/papers/unpinned-paper")

      assert conn200.status == 200
      assert [etag] = get_resp_header(conn200, "etag")
      assert etag == weak_etag(stored_content(unpinned))
      # x-barkpark-paper-revision stays rrid-gated: no revision, no header.
      assert get_resp_header(conn200, "x-barkpark-paper-revision") == []

      conn304 = replay("/papers/unpinned-paper", etag)
      assert conn304.status == 304
    end

    test "the released revision id rides along when pinned", %{conn: conn, paper: paper} do
      conn200 = get(conn, "/papers/conditional-paper")
      paper = Repo.get!(Document, paper.id)

      assert get_resp_header(conn200, "x-barkpark-paper-revision") ==
               [paper.released_revision_id]
    end
  end

  describe "dataset-prefixed /d/:dataset/papers/:slug — emit + honor (D9)" do
    test "emits the weak bucketed etag and honors it with a 304", %{conn: conn, paper: paper} do
      conn200 = get(conn, "/d/#{@dataset}/papers/conditional-paper")

      assert conn200.status == 200
      assert [etag] = get_resp_header(conn200, "etag")
      assert etag == weak_etag(stored_content(paper))

      conn304 = replay("/d/#{@dataset}/papers/conditional-paper", etag)

      assert conn304.status == 304
      assert conn304.resp_body == ""
      assert get_resp_header(conn304, "content-security-policy") == []
    end
  end

  describe "time bucket (D9)" do
    test "an adjacent bucket window flips the 304 back to 200", %{paper: paper} do
      digest = EpicFleet.canonical_digest(stored_content(paper))
      stale = ~s(W/"sha256:#{digest}.#{build_digest()}.#{current_bucket() - 1}")

      conn = replay("/papers/conditional-paper", stale)

      assert conn.status == 200
      assert html_response(conn, 200) =~ "Conditional Paper"
    end
  end

  describe "build identity" do
    test "a validator from an older rendered shell cannot 304 after a rebuild", %{paper: paper} do
      content_digest = EpicFleet.canonical_digest(stored_content(paper))
      old_build_digest = String.duplicate("0", 64)
      refute old_build_digest == build_digest()

      old_build_etag =
        ~s(W/"sha256:#{content_digest}.#{old_build_digest}.#{current_bucket()}")

      legacy_content_only_etag = ~s(W/"sha256:#{content_digest}.#{current_bucket()}")

      conn200 = replay("/papers/conditional-paper", old_build_etag)
      assert conn200.status == 200
      assert html_response(conn200, 200) =~ "Conditional Paper"
      assert replay("/papers/conditional-paper", legacy_content_only_etag).status == 200

      [current_etag] = get_resp_header(conn200, "etag")
      refute current_etag == old_build_etag
      assert replay("/papers/conditional-paper", current_etag).status == 304
    end
  end

  describe "If-None-Match semantics (D11)" do
    test "list form: our etag anywhere in a comma-separated list matches", %{paper: paper} do
      etag = weak_etag(stored_content(paper))
      conn = replay("/papers/conditional-paper", ~s("mismatch-a", "mismatch-b", #{etag}))

      assert conn.status == 304
    end

    test "star matches any current representation" do
      conn = replay("/papers/conditional-paper", "*")

      assert conn.status == 304
    end

    test "weak comparison: a strong-form tag matches our weak etag", %{paper: paper} do
      strong = String.replace_prefix(weak_etag(stored_content(paper)), "W/", "")
      conn = replay("/papers/conditional-paper", strong)

      assert conn.status == 304
    end

    test "a non-matching tag stays a 200" do
      conn = replay("/papers/conditional-paper", ~s(W/"sha256:not-the-digest.0"))

      assert conn.status == 200
    end

    # DELEGATION GUARD — this plug was the D11 reference implementation and now
    # calls BarkparkWeb.Http.IfNoneMatch. Multi-line folding was the one D11
    # clause this describe never pinned; it is also the clause the other three
    # sites gained. Green before and after: it guards the extraction, not a
    # behaviour change here.
    test "a match on the SECOND If-None-Match header line matches", %{paper: paper} do
      etag = weak_etag(stored_content(paper))

      conn =
        scoped_conn()
        |> then(fn c ->
          %{
            c
            | req_headers:
                c.req_headers ++ [{"if-none-match", ~s("nope")}, {"if-none-match", etag}]
          }
        end)
        |> get("/papers/conditional-paper")

      assert conn.status == 304
    end

    # Empty list entries are dropped, never matched.
    test "a header of nothing but separators stays a 200" do
      conn = replay("/papers/conditional-paper", ", ,")

      assert conn.status == 200
    end
  end

  describe "live task blocks are excluded (D9)" do
    setup %{ws: ws, project: project} do
      {:ok, task_paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "live-task-paper",
            "dataset" => @dataset,
            "blocks" => [
              %{
                "id" => "tp-intro",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Board below."}]
              },
              %{"id" => "tp-board", "type" => "task-board", "query" => %{"status" => "open"}}
            ],
            "workspace_id" => ws.id,
            "project_id" => project.id
          })
        )

      {:ok, task_paper: task_paper}
    end

    test "a paper with a live task block emits NO etag on either flat route and never 304s",
         %{conn: conn} do
      flat = get(conn, "/papers/live-task-paper")
      assert flat.status == 200
      assert get_resp_header(flat, "etag") == []

      prefixed = get(scoped_conn(), "/d/#{@dataset}/papers/live-task-paper")
      assert prefixed.status == 200
      assert get_resp_header(prefixed, "etag") == []

      # Even a star conditional never converts: there is no validator to honor.
      conn = replay("/papers/live-task-paper", "*")
      assert conn.status == 200
    end

    test "the predicate recurses into container children (direct call, no render)",
         %{ws: ws, project: project} do
      {:ok, nested} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "nested-task-paper",
            "dataset" => @dataset,
            "blocks" => [
              %{
                "id" => "np-section",
                "type" => "section",
                "children" => [
                  %{"id" => "np-tasks", "type" => "tasks", "query" => %{"tag" => "infra"}}
                ]
              }
            ],
            "workspace_id" => ws.id,
            "project_id" => project.id
          })
        )

      _ = nested

      conn =
        Plug.Test.conn(:get, "/papers/nested-task-paper")
        |> PaperRevisionHeaders.call([])

      assert get_resp_header(conn, "etag") == []
      refute conn.halted
    end

    test "a query-less task-typed block is NOT live — the etag still flows (direct call)",
         %{ws: ws, project: project} do
      {:ok, static} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "static-task-paper",
            "dataset" => @dataset,
            "blocks" => [
              %{
                "id" => "sp-intro",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Static board."}]
              },
              %{"id" => "sp-board", "type" => "task-board"}
            ],
            "workspace_id" => ws.id,
            "project_id" => project.id
          })
        )

      conn =
        Plug.Test.conn(:get, "/papers/static-task-paper")
        |> PaperRevisionHeaders.call([])

      assert get_resp_header(conn, "etag") == [weak_etag(stored_content(static))]
    end
  end

  describe "fail-closed self-gating (direct call)" do
    test "a missing slug leaves the conn untouched" do
      conn =
        Plug.Test.conn(:get, "/papers/no-such-paper-xyz")
        |> PaperRevisionHeaders.call([])

      assert get_resp_header(conn, "etag") == []
      assert get_resp_header(conn, "x-barkpark-paper-revision") == []
      refute conn.halted
    end

    test "a draft paper leaves the conn untouched", %{paper: paper} do
      paper |> Ecto.Changeset.change(status: "draft") |> Repo.update!()

      conn =
        Plug.Test.conn(:get, "/papers/conditional-paper")
        |> PaperRevisionHeaders.call([])

      assert get_resp_header(conn, "etag") == []
      refute conn.halted
    end

    test "non-paper sibling paths on the shared bucket fall through untouched" do
      for path <- ["/sheets/some-sheet", "/quiz/host/1234", "/finder"] do
        conn = Plug.Test.conn(:get, path) |> PaperRevisionHeaders.call([])

        assert get_resp_header(conn, "etag") == [], "expected no etag for #{path}"
        refute conn.halted
      end
    end

    test "the scoped spelling still honors a matching conditional (direct call)",
         %{ws: ws, project: project, paper: paper} do
      etag = weak_etag(stored_content(paper))

      conn =
        Plug.Test.conn(:get, "/w/#{ws.slug}/p/#{project.slug}/papers/conditional-paper")
        |> Plug.Conn.assign(:current_workspace, ws)
        |> Plug.Conn.assign(:current_project, project)
        |> put_req_header("if-none-match", etag)
        |> PaperRevisionHeaders.call([])

      assert conn.halted
      assert conn.status == 304
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [etag]
    end
  end

  # ── published-perspective clamp: a drafts.-id row bypassing the writer ────
  #
  # `Writer.create_document/4` / `upsert_document/4` coerce a caller-supplied
  # `status: "published"` to `"draft"` the instant `doc_id` is `drafts.`-
  # prefixed, and `Lifecycle.do_publish_document/4` writes `status:
  # "published"` only onto the BARE `DraftId.published_id/1` row — so in
  # every real write path this row can never exist. That write-side
  # invariant is exactly why this plug was SAFE despite reading only
  # `status == "published"` with no `drafts.` prefix conjunct. This suite
  # bypasses the writer entirely (`Document.changeset/2` + `Repo.insert!`,
  # same raw-insert shape `pin_released_revision!/1` below already uses) to
  # construct the incoherent row directly and assert the READ SIDE refuses
  # it on its own — not relying on the write invariant holding forever.
  describe "published-perspective clamp: a drafts.-id row bypassing the writer" do
    test "flat /papers/:slug: a drafts.-prefixed row with status \"published\" emits no etag or revision header",
         %{ws: ws, project: project} do
      leak = insert_bypassing_writer!(ws, project, "drafts.leak-flat")

      conn =
        Plug.Test.conn(:get, "/papers/drafts.leak-flat")
        |> PaperRevisionHeaders.call([])

      refute conn.halted
      assert get_resp_header(conn, "etag") == []
      assert get_resp_header(conn, "x-barkpark-paper-revision") == []
      # `cache-control` is NOT asserted absent here — a bare `%Plug.Conn{}`
      # carries `"max-age=0, private, must-revalidate"` as ITS OWN default
      # (see `Plug.Conn` moduledoc), so this plug's own
      # `put_resp_header("cache-control", …)` is indistinguishable from that
      # default on a direct-call conn; the etag/revision absence above is the
      # load-bearing assertion (matches the sibling "a draft paper leaves the
      # conn untouched" test above, same reason).
      # Guard the fixture itself: the row really exists at the drafts. id
      # with an (incoherent) published status, or the refusal above is vacuous.
      assert Repo.get!(Document, leak.id).status == "published"
      assert Repo.get!(Document, leak.id).doc_id == "drafts.leak-flat"
    end

    test "dataset-prefixed /d/:dataset/papers/:slug: same clamp", %{ws: ws, project: project} do
      insert_bypassing_writer!(ws, project, "drafts.leak-dataset")

      conn =
        Plug.Test.conn(:get, "/d/#{@dataset}/papers/drafts.leak-dataset")
        |> PaperRevisionHeaders.call([])

      refute conn.halted
      assert get_resp_header(conn, "etag") == []
    end

    test "scoped /w/:ws/p/:project/papers/:slug: same clamp", %{ws: ws, project: project} do
      insert_bypassing_writer!(ws, project, "drafts.leak-scoped")

      conn =
        Plug.Test.conn(:get, "/w/#{ws.slug}/p/#{project.slug}/papers/drafts.leak-scoped")
        |> Plug.Conn.assign(:current_workspace, ws)
        |> Plug.Conn.assign(:current_project, project)
        |> PaperRevisionHeaders.call([])

      refute conn.halted
      assert get_resp_header(conn, "etag") == []
    end

    test "positive control: the same bypass at a BARE (non-prefixed) doc_id still emits the etag",
         %{ws: ws, project: project} do
      insert_bypassing_writer!(ws, project, "leak-control-bare")

      conn =
        Plug.Test.conn(:get, "/papers/leak-control-bare")
        |> PaperRevisionHeaders.call([])

      refute conn.halted
      assert [_etag] = get_resp_header(conn, "etag")
    end
  end

  # Bypasses `Writer.create_document/4` / `upsert_document/4` entirely — a raw
  # `Document.changeset/2` + `Repo.insert!`, same shape as
  # `pin_released_revision!/1` below — so the writer's `drafts.`-prefix ⇒
  # coerce-status-to-draft invariant cannot intervene. This is the ONLY way to
  # get a `drafts.`-prefixed row with `status: "published"` into the table;
  # every real write path refuses to produce one (see the describe block's
  # header comment).
  defp insert_bypassing_writer!(ws, project, doc_id) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => doc_id,
      "type" => "paper",
      "dataset" => @dataset,
      "status" => "published",
      "rev" => Barkpark.Content.Writer.generate_rev(),
      "workspace_id" => ws.id,
      "project_id" => project.id,
      "content" => %{
        "blocks" => [
          %{
            "id" => "b1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "DRAFT-ONLY-SECRET"}]
          }
        ]
      }
    })
    |> Repo.insert!()
  end

  defp pin_released_revision!(paper) do
    revision =
      %Revision{}
      |> Revision.changeset(%{
        document_id: paper.id,
        doc_id: paper.doc_id,
        type: paper.type,
        dataset: paper.dataset,
        dataset_id: paper.dataset_id,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id,
        title: paper.title,
        status: paper.status,
        action: "publish",
        content: paper.content
      })
      |> Repo.insert!()

    paper
    |> Ecto.Changeset.change(
      current_revision_id: revision.id,
      released_revision_id: revision.id
    )
    |> Repo.update!()
  end
end
