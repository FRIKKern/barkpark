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
  siblings (sheets/quiz/finder/share) fall through untouched. The flat
  spellings mirror `Papers.get_public_document/3` in ONE query: the Document
  joined to the Default workspace by slug — NO project_id predicate (the
  public reader scopes by workspace only), `status == "published"` only. No
  row (including an unseeded Default workspace) leaves the conn untouched.
  """

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.EpicFleet
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Workspace

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

  defp scoped_paper(workspace, project, slug) do
    Repo.one(
      from document in Document,
        where:
          document.workspace_id == ^workspace.id and document.project_id == ^project.id and
            document.type == "paper" and document.dataset == "production" and
            document.doc_id == ^slug and document.status == "published",
        select: %{
          released_revision_id: document.released_revision_id,
          content: document.content
        }
    )
  end

  # Mirrors Papers.get_public_document/3 (Default-workspace pinning, fail
  # closed) in ONE query — workspace scope only, no project_id predicate.
  defp default_public_paper(slug, dataset) do
    Repo.one(
      from document in Document,
        join: workspace in Workspace,
        on: document.workspace_id == workspace.id,
        where:
          workspace.slug == "default" and document.type == "paper" and
            document.dataset == ^dataset and document.doc_id == ^slug and
            document.status == "published",
        select: %{
          released_revision_id: document.released_revision_id,
          content: document.content
        }
    )
  end

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

  defp weak_etag(content) do
    bucket = div(System.os_time(:second), @bucket_seconds)
    ~s(W/"sha256:#{EpicFleet.canonical_digest(content)}.#{bucket}")
  end

  # D11: fold all values, comma-split, trim, honor *, weak compare.
  defp if_none_match?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(fn candidate ->
      candidate == "*" or strip_weak(candidate) == strip_weak(etag)
    end)
  end

  defp strip_weak("W/" <> opaque_tag), do: opaque_tag
  defp strip_weak(opaque_tag), do: opaque_tag

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
