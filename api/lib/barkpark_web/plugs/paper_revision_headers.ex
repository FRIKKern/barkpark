defmodule BarkparkWeb.Plugs.PaperRevisionHeaders do
  @moduledoc """
  Weak, time-bucketed ETag + honored conditional for the paper reader
  (http-edge-truth charter D9/D10/D11).

  ## What it does

  On every PUBLISHED paper response — flat `/papers/:slug`, dataset-prefixed
  `/d/:dataset/papers/:slug`, and scoped `/w/:ws/p/:proj/papers/:slug` — the
  plug emits

      etag: W/"sha256:<canonical_digest(content)>.<bucket>"

  and answers a matching `If-None-Match` with an empty `304 Not Modified`,
  halting BEFORE the LiveView dead render. `x-barkpark-paper-revision` still
  rides along only when a released revision is pinned (rrid-gated; D9 dropped
  that gate for the ETag itself — the validator is the content digest, not the
  revision pointer).

  ## Why weak + bucketed (D9)

  The reader body legitimately varies per request (CSP nonce, LiveView session
  token — ~12 lines), so the validator is WEAK: semantic equivalence, not
  byte equality. `bucket = div(System.os_time(:second), 604_800)` folds a
  7-day UTC window into the tag so a cached entry can never stay fresh past
  the bucket edge — bounding staleness BELOW the 14-day LiveView token expiry
  that otherwise turns a valid 304 into a same-URL redirect loop (the revived
  HTML's expired LV token dead-loops the client).

  ## Cache policy (second-review condition 1)

  Every matched published-paper response carries
  `cache-control: private, max-age=0, must-revalidate` — the reader HTML
  embeds per-visitor state (CSRF token, LiveView session token), so a shared
  or proxy cache must never store it, and without an explicit policy the
  ETag-only response left freshness to engine-variable heuristics (RFC 9111
  §4.2.2). Same shape as `share_link_controller.ex` / `media_controller.ex`.

  ## The 304 branch (D10)

  RFC 9110 §15.4.5: the 304 re-emits the SAME `etag` + `cache-control` the
  200 would carry. Header update on 304 is MERGE, not replace (RFC 9111
  §3.2 — absent fields are RETAINED; source-verified in Gecko, WebKit, and
  Blink by the independent second review, ledger row
  `csp-304-second-review-verdict-2026-08-08.md`). But the
  `content-security-policy` minted eagerly by `PaperReaderCsp` is DELETED:
  that policy allowlists a fresh nonce the cached HTML does not carry, so a
  304 delivering it would permanently break the revived reader's inline
  scripts in every conforming browser.

  ## Exclusion: live task blocks (D9)

  A paper embedding a live task block renders volatile task state, so it gets
  NO validator and never 304s. The predicate is reimplemented from
  `BarkparkWeb.BulldocsLive.has_live_task_blocks?/1` (bulldocs_live.ex:766 —
  `@task_block_types` + a map `query`, recursing into container children);
  that module is fenced (cch), so the logic lives here as a copy — keep the
  two in sync by hand.

  ## If-None-Match semantics (D11)

  One matcher: fold ALL `if-none-match` header values, split on commas, trim,
  honor `*`, and compare weakly — strip a leading `W/` from BOTH sides, then
  compare the full quoted opaque-tag octet-for-octet. Comma-splitting is safe
  here because every tag this plug mints is comma-free (hex digest + digits).

  ## Scoping (fail closed)

  The plug SELF-GATES on `path_info`; the shared `:public_root` bucket's
  siblings (sheets/quiz/finder/share) fall through untouched. Both queries
  below enforce the published perspective directly — `status == "published"`
  AND `doc_id` is not `drafts.`-prefixed — rather than delegating to (or
  merely resembling) another module's resolver: the prefix conjunct reuses
  `DraftId.drafts_prefix()`, the SAME constant and `not like/2` idiom
  `Barkpark.Content.Query.maybe_published_only/2` applies for every other
  anonymous/public read (D5). A `drafts.`-prefixed row is never a valid
  published read here even if its `status` column incoherently reads
  "published" — which the write chokepoint (`Writer.create_document/4`,
  `upsert_document/4`) already refuses to produce, so this clamp is
  belt-and-braces on the read side, not the only thing standing between a
  write bug and a leak.

  The flat spellings additionally scope to the Default workspace by slug — NO
  project_id predicate (the public reader scopes by workspace only). No row
  (including an unseeded Default workspace, or a `drafts.`-prefixed row) ever
  leaves the conn untouched.
  """

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.DraftId
  alias Barkpark.EpicFleet
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Workspace
  alias BarkparkWeb.Http.IfNoneMatch

  @bucket_seconds 604_800

  # Reimplemented from BarkparkWeb.BulldocsLive (bulldocs_live.ex:766) — that
  # module is fenced (cch); never import from it. Keep in sync by hand.
  @task_block_types ~w(tasks task-list task-board roadmap task-detail)

  def init(opts), do: opts

  def call(
        %Plug.Conn{
          path_info: ["w", _workspace, "p", _project, "papers", slug],
          assigns: %{current_workspace: workspace, current_project: project}
        } = conn,
        _opts
      ) do
    respond(conn, scoped_paper(workspace, project, slug))
  end

  def call(%Plug.Conn{path_info: ["papers", slug]} = conn, _opts) do
    respond(conn, default_public_paper(slug, Content.paper_default_dataset()))
  end

  def call(%Plug.Conn{path_info: ["d", dataset, "papers", slug]} = conn, _opts) do
    respond(conn, default_public_paper(slug, dataset))
  end

  def call(conn, _opts), do: conn

  # Same published-perspective clamp as `default_public_paper/2` below —
  # `status == "published"` AND `doc_id` not `drafts.`-prefixed. See the
  # moduledoc's "Scoping (fail closed)" section.
  defp scoped_paper(workspace, project, slug) do
    drafts_prefix = drafts_like_prefix()

    Repo.one(
      from document in Document,
        where:
          document.workspace_id == ^workspace.id and document.project_id == ^project.id and
            document.type == "paper" and document.dataset == "production" and
            document.doc_id == ^slug and document.status == "published" and
            not like(document.doc_id, ^drafts_prefix),
        select: %{
          released_revision_id: document.released_revision_id,
          content: document.content
        }
    )
  end

  # Default-workspace pinning, fail closed — workspace scope only, no
  # project_id predicate. Published-perspective clamp: `status == "published"`
  # AND `doc_id` not `drafts.`-prefixed, reusing `DraftId.drafts_prefix()` and
  # the same `not like/2` idiom `Content.Query.maybe_published_only/2` applies
  # everywhere else on the anonymous/public read path (D5). See the
  # moduledoc's "Scoping (fail closed)" section.
  defp default_public_paper(slug, dataset) do
    drafts_prefix = drafts_like_prefix()

    Repo.one(
      from document in Document,
        join: workspace in Workspace,
        on: document.workspace_id == workspace.id,
        where:
          workspace.slug == "default" and document.type == "paper" and
            document.dataset == ^dataset and document.doc_id == ^slug and
            document.status == "published" and not like(document.doc_id, ^drafts_prefix),
        select: %{
          released_revision_id: document.released_revision_id,
          content: document.content
        }
    )
  end

  defp drafts_like_prefix, do: DraftId.drafts_prefix() <> "%"

  defp respond(conn, nil), do: conn

  defp respond(conn, %{released_revision_id: revision, content: content}) do
    conn =
      conn
      |> maybe_put_revision(revision)
      |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")

    if has_live_task_blocks?(content) do
      conn
    else
      etag = weak_etag(content)
      conn = put_resp_header(conn, "etag", etag)

      if if_none_match?(conn, etag) do
        conn
        |> delete_resp_header("content-security-policy")
        |> send_resp(304, "")
        |> halt()
      else
        conn
      end
    end
  end

  defp maybe_put_revision(conn, revision) when is_binary(revision),
    do: put_resp_header(conn, "x-barkpark-paper-revision", revision)

  defp maybe_put_revision(conn, _revision), do: conn

  # ── CITED SAFE (NOT FIXED) — class C, a WINDOW KEY that keys no shared
  # mutable state (clock-semantics wave, 2026-08-19). Read this before
  # re-deriving it, and before re-sourcing this clock.
  #
  # Provenance: swept as a sibling of the cloud rate-limiter defect closed by
  # #12628 (8598c4efe7), where a window derived from a non-monotonic wall clock
  # was used as a BUCKET KEY, so a caller holding a stale window could DELETE a
  # newer bucket and reset the budget (the earlier atomicity fix was #12579,
  # e45f1377bb). `bucket = div(System.os_time(:second), @bucket_seconds)` below
  # is genuinely that quantiser shape, which is why it is class C and not
  # class A — so the verdict is CITED, not "not a candidate".
  #
  # (a) STRUCTURAL, stated before any argument about consequences: there is no
  #     shared mutable state for a stale bucket to address. `weak_etag/1` is
  #     private, has exactly ONE caller (`respond/2` above), and its value is
  #     interpolated into a response header and discarded. Nothing is stored
  #     under the bucket, nothing is swept by it, nothing is deleted. #12628's
  #     stale-writer-deletes-a-newer-bucket shape has NO analogue here: the
  #     worst a bucket-boundary straddle can do is emit a tag the client does
  #     not hold, which costs exactly one extra full 200.
  #
  # (b) CONSUMER CENSUS. The bucket has one reader: the tag string. The tag has
  #     one comparator: `if_none_match?/2` below, which weak-compares the
  #     client's candidates against the tag the server JUST computed in this
  #     same request — so a client cannot present an OLDER bucket and be served
  #     a 304 from it (pinned by paper_revision_headers_test.exs, "an adjacent
  #     bucket window flips the 304 back to 200"). The bucket is never parsed,
  #     never persisted, never used as a map or ETS key: `grep -n bucket` in
  #     this file returns only `@bucket_seconds` and the two lines here.
  #
  # The bound the bucket exists to hold is real and config-unreachable:
  # phoenix_live_view is LOCKED at 1.1.28 in api/mix.lock, whose
  # `@max_session_age` is the compile-time constant 1_209_600 (14 days) with no
  # option or config seam, and api/config carries no live_view max_age
  # override. A 7-day bucket under a 14-day token is 7 days of slack.
  # CLOCK STEP, both directions: a FORWARD step TIGHTENS the bound — the tag
  # changes early and the cost is extra 200s. A BACKWARD step is the only
  # direction that can loosen it, and it must be at least ONE FULL BUCKET WIDTH
  # (604_800 s) before a body older than 14 days could revalidate.
  #
  # RESIDUAL, named in the safe direction and accepted: what a full-width
  # backward step would breach is a LIVENESS bound (revived HTML carrying an
  # expired LiveView token dead-loops the client), on an anonymously reachable
  # public reader — not authorization, not a quota. It is unreachable without a
  # host clock event, and a caller has ZERO influence on the timing: no request
  # value feeds this read.
  #
  # THE REFUSAL IS PART OF THE VERDICT: re-keying this bucket to
  # `System.monotonic_time` would be WRONG, for the same reason the incarnation
  # class exists (see `Barkpark.StudioChat.FleetHub`). Monotonic RESETS on
  # restart — exactly the moment body turnover must still be guaranteed — so a
  # monotonic bucket would silently stop bounding staleness across every deploy.
  # A correct monotonic-anchored bucket would need a persisted watermark, i.e. a
  # new mechanism, which this wave explicitly forbids. Wall clock is the right
  # source here; the class-C label is a warning to future readers, not a TODO.
  #
  # WHAT THIS VERDICT DOES NOT REST ON: the fact that this plug already shipped
  # with a green suite and a second review. A prior green stamp is not evidence
  # about clock semantics — the reviews that passed this code graded it on HTTP
  # conditional-request correctness (the weak-validator, 304 and If-None-Match
  # rows of the http-edge-truth charter named in the moduledoc above), never on
  # what a clock step does to the bucket. The two grounds above are structural
  # (no shared mutable state) and a consumer census; neither leans on that
  # history.
  defp weak_etag(content) do
    bucket = div(System.os_time(:second), @bucket_seconds)
    ~s(W/"sha256:#{EpicFleet.canonical_digest(content)}.#{bucket}")
  end

  # D11 lives in BarkparkWeb.Http.IfNoneMatch now — this plug was its original source.
  defp if_none_match?(conn, etag), do: IfNoneMatch.match?(conn, etag)

  defp has_live_task_blocks?(%{"blocks" => blocks}) when is_list(blocks),
    do: any_live_task?(blocks)

  defp has_live_task_blocks?(_content), do: false

  defp any_live_task?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{"type" => type, "query" => query} when is_map(query) -> type in @task_block_types
      %{"children" => children} when is_list(children) -> any_live_task?(children)
      _ -> false
    end)
  end

  defp any_live_task?(_blocks), do: false
end
