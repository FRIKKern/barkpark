defmodule BarkparkWeb.BulldocsReaderDeletedPaperTest do
  @moduledoc """
  pd-ee-reader-stale-cache — publish → read → delete → read, on the public
  Paper reader (`/papers/:slug`, `BulldocsLive`).

  ## The 2026-07-11 report

  "After a confirmed delete mutation (delete revision present in
  `/v1/data/history`, row gone from the paper-list query), `GET /papers/<slug>`
  KEPT returning HTTP 200 with the old title." The reporter suspected an
  unidentified cache layer (Cachex / ETS / CDN).

  ## The verdict, driven against current main

  **The new-request half does NOT reproduce.** After the delete:
  `Content.get_public_paper/2` returns `nil`, a `"delete"` revision is in
  history, and a brand-new request raises `BulldocsLive.NotFound`
  (`plug_status: 404`) out of `mount/3` — pinned below.

  There is no Cachex, no `:ets` and no `:persistent_term` anywhere between the
  route and `Content.get_public_paper/2` (grepped across `bulldocs_live.ex`,
  `plugins/bulldocs*`, and `content/papers.ex`); the only thing named "cache"
  in the reader itself is the `body_html` the paper document CARRIES, which
  dies with the row.

  There IS now an HTTP validator the 2026-07-11 reporter could not have seen:
  `BarkparkWeb.Plugs.PaperRevisionHeaders` (http-edge-truth D9/D10/D11) mints a
  weak time-bucketed ETag and honours `If-None-Match` with a `304`, halting
  BEFORE the dead render. That is the closest thing in the tree to the
  suspected "cache layer", so it is driven here too, not reasoned about: its
  query requires a LIVE published row, so a deleted paper mints no validator
  and a conditional revalidation carrying the pre-delete ETag gets the 404 —
  never a 304 that would let a browser revive its cached copy of deleted
  content. Pinned below.

  **The connected-reader half DOES reproduce, and it is the real leak.** A
  reader already mounted on the URL kept rendering the deleted paper's body
  indefinitely — and NOT for the reason it first looks like:

    * `Broadcast.tap_broadcast/7` emits `{:doc_updated, msg}` on the per-doc
      topic (plus `{:document_changed, msg}` on the global + workspace streams);
    * the reader IS on that topic already — `Content.paper_topic/3` and
      `Content.doc_topic/4` build the SAME string for a paper, because a
      paper's doc_id is its slug and `paper_topic/3` is the doc topic with the
      type pinned to `"paper"`. That identity is asserted below, so a rename
      that splits them apart reds here;
    * but the reader matched only `{:paper_updated, …}`, which the paper-write
      pipeline emits and delete never does. Its
      `{:document_changed, %{type: "paper"}}` clause reacts only to papers in
      `@paper_link_refs` — LINKED papers, never its own.

  So the delete frame ARRIVED and fell into the catch-all. The fix is one
  `handle_info/2` clause; no new subscription is needed, and adding one is
  measurably useless — removing it left the connected case green, while
  removing the clause reds it (both mutations run; see the PR).

  The most plausible shape of the original observation is therefore a browser
  tab (or an unfurler holding a socket) that was ALREADY on the page, not a
  fresh GET.

  ## A trap this file had to route around

  Calling `Content.delete_document/4` DIRECTLY from a test is not a valid
  fixture for the connected arm. `Broadcast.maybe_broadcast/2` queues instead of
  broadcasting whenever `Repo.in_transaction?()` — which is ALWAYS true under
  the SQL sandbox — and only `Content.apply_mutations/3` flushes that queue on
  commit. A direct call therefore delivers NO message at all, so a
  connected-reader test written that way shows "body survives" whether the bug
  exists or not, and shows it identically after the fix. Every delete here goes
  through the `/v1/data/mutate` `delete` op (`Content.apply_mutations/3`) so the
  broadcast the production path actually emits is the broadcast under test.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  defp publish_paper!(slug, title) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          title: title,
          body_html: ~s(<section id="block-1"><h1>#{title}</h1></section>)
        })
      )

    assert paper.status == "published"
    paper
  end

  # The API's delete path — the `/v1/data/mutate` `delete` op. NOT
  # `Content.delete_document/4` directly: see "A trap this file had to route
  # around" above.
  defp delete_via_mutate!(paper) do
    :ok =
      Content.apply_mutations(
        [%{"delete" => %{"id" => Content.published_id(paper.doc_id), "type" => "paper"}}],
        Content.paper_default_dataset(),
        source: :api,
        workspace_id: paper.workspace_id
      )
      |> elem(0)

    :ok
  end

  defp nodes(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.to_list()
  end

  defp body_title(html), do: html |> nodes("#paper-body h1") |> Enum.map(&LazyHTML.text/1)

  describe "a NEW request for a deleted paper" do
    test "404s — no stale layer between the route and canonical storage" do
      slug = "reader-delete-fresh-request"
      paper = publish_paper!(slug, "Scratch Before Delete")

      # BEFORE: 200, and the title is in the article body (an element, not a
      # substring of the whole page — the slug alone appears in chrome).
      before_conn = get(Phoenix.ConnTest.build_conn(), "/papers/#{slug}")
      assert before_conn.status == 200
      assert body_title(before_conn.resp_body) == ["Scratch Before Delete"]

      delete_via_mutate!(paper)

      # Absent from canonical storage…
      refute Content.get_public_paper(slug, Content.paper_default_dataset())

      # …and present in history, exactly as the 2026-07-11 report described the
      # state it was in when it still saw a 200.
      actions =
        Content.published_id(paper.doc_id)
        |> Content.list_revisions("paper", Content.paper_default_dataset())
        |> Enum.map(&Map.get(&1, :action))

      assert "delete" in actions

      # AFTER, on a BRAND-NEW connection: 404 out of BulldocsLive.mount/3, and
      # the old title is nowhere in the response.
      assert {404, _headers, body} =
               assert_error_sent(404, fn ->
                 get(Phoenix.ConnTest.build_conn(), "/papers/#{slug}")
               end)

      refute body =~ "Scratch Before Delete"
    end

    test "a conditional revalidation with the pre-delete ETag gets 404, not 304" do
      # The closest thing in the tree to the reported "cache layer":
      # PaperRevisionHeaders mints a weak ETag and answers If-None-Match with a
      # 304 that halts before the dead render. A 304 here would let every
      # browser holding the cached page keep reading the deleted paper — the
      # 2026-07-11 symptom, in the one shape a `curl` without conditional
      # headers could never have produced.
      slug = "reader-delete-conditional"
      paper = publish_paper!(slug, "Conditional Before Delete")

      before_conn = get(Phoenix.ConnTest.build_conn(), "/papers/#{slug}")
      assert before_conn.status == 200
      assert [etag] = Plug.Conn.get_resp_header(before_conn, "etag")

      # The validator is live BEFORE the delete — otherwise the arm below is
      # vacuous (a 404 proves nothing if no 304 was ever reachable).
      revalidated =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> get("/papers/#{slug}")

      assert revalidated.status == 304

      delete_via_mutate!(paper)

      assert {404, _headers, body} =
               assert_error_sent(404, fn ->
                 Phoenix.ConnTest.build_conn()
                 |> Plug.Conn.put_req_header("if-none-match", etag)
                 |> get("/papers/#{slug}")
               end)

      refute body =~ "Conditional Before Delete"
    end
  end

  describe "a reader already connected when the paper is deleted" do
    test "the paper topic and the paper's doc topic are the same string" do
      # The load-bearing assumption behind "no new subscription": the reader
      # subscribes with paper_topic/3 at mount, the delete broadcasts with
      # doc_topic/4, and they are the same topic. If a refactor ever splits
      # them, the delete frame stops arriving and the leak reopens silently —
      # so it reds HERE instead.
      paper = publish_paper!("reader-delete-topic-identity", "Topic Identity")
      ds = Content.paper_default_dataset()

      assert Content.paper_topic("reader-delete-topic-identity", paper.workspace_id, ds) ==
               Content.doc_topic(
                 Content.published_id(paper.doc_id),
                 "paper",
                 paper.workspace_id,
                 ds
               )
    end

    test "transitions to not-found instead of serving the deleted body" do
      slug = "reader-delete-connected"
      paper = publish_paper!(slug, "Connected Before Delete")

      {:ok, view, html} = live(Phoenix.ConnTest.build_conn(), "/papers/#{slug}")

      assert body_title(html) == ["Connected Before Delete"]
      assert nodes(html, "#paper-empty") == []

      delete_via_mutate!(paper)

      after_html = render(view)

      # The leak: this used to still be ["Connected Before Delete"].
      assert body_title(after_html) == []
      assert [_] = nodes(after_html, "#paper-empty")

      # It is a TRANSITION, not a crash — the reader stays mounted and shows the
      # honest empty state. A dead LiveView would also stop serving the body and
      # would pass a naive "body is gone" assertion.
      assert Process.alive?(view.pid)
    end

    test "a reader on a DIFFERENT paper is untouched by the delete" do
      # The control. Without it, a fix that refetched on EVERY document frame in
      # the tenant would pass the case above while quietly making every public
      # reader re-read on every unrelated write.
      victim = publish_paper!("reader-delete-victim", "Victim Paper")
      publish_paper!("reader-delete-bystander", "Bystander Paper")

      {:ok, bystander_view, _} =
        live(Phoenix.ConnTest.build_conn(), "/papers/reader-delete-bystander")

      delete_via_mutate!(victim)

      after_html = render(bystander_view)

      assert body_title(after_html) == ["Bystander Paper"]
      assert nodes(after_html, "#paper-empty") == []
    end
  end
end
