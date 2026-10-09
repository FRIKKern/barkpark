defmodule BarkparkWeb.PreviewLinkController do
  @moduledoc """
  task-6812c3100d7aedbc — DRAFT-capable preview links for J64's share menu.

    * `GET /sp/:token` — PUBLIC. Resolves the opaque link and serves that one
      document (draft or published), scoped to the LINK's own
      workspace/project/dataset (never the request). JSON only — there is no
      paper/media kind to special-case the way `/s/:token` does.
    * `POST/GET/DELETE /v1/shares/preview-links` — ADMIN. Mint (raw token
      shown once), list a document's links, revoke one.

  Deliberately NOT mounted under `/v1/preview/*`: that prefix already belongs
  to the unrelated `PreviewToken` JWT mechanism (header-borne signed token,
  `perspective=drafts`, `:api_preview` pipeline) — reusing the word there
  would collide two different auth schemes under one path.

  A link's `doc_id` is NOT a published id — see `Barkpark.Sharing.PreviewLink`
  moduledoc for why this is a sibling of `ShareLinkController`, not a branch of
  it: `Barkpark.Sharing.Links.published_ref_id/1` would strip exactly the
  prefix this feature exists to keep.

  Tenancy confinement mirrors `ShareLinkController` verbatim: `:require_admin`
  proves the caller holds `admin` SOMEWHERE, so `mint`/`list`/`revoke`
  additionally require the caller to administer the TARGET workspace
  (`PreviewLinks.workspace_admin?/2`, which delegates to the same
  `Tenancy.Auth.workspace_admin?/2` chokepoint `Links.workspace_admin?/2` does).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope
  alias Barkpark.Sharing
  alias Barkpark.Sharing.PreviewLinks
  alias Barkpark.Tenancy
  alias BarkparkWeb.ErrorResponse

  # ── PUBLIC resolver ──────────────────────────────────────────────────────

  # HARDENING for a draft served by a bearer-in-URL token (team-lead review):
  #   * referrer-policy: no-referrer — overrides ApiSecurityHeaders'
  #     strict-origin-when-cross-origin baseline. A referrer header on any
  #     outbound link FROM this response would carry the raw token (it rides
  #     the URL path) to whatever site that link points at.
  #   * cache-control: private, no-store — an intermediary or the browser's
  #     own disk cache must never retain a draft body keyed on a secret that
  #     can be revoked out from under it.
  #   * x-robots-tag: noindex — same stance as ReaderNoindex for the paper
  #     reader, applied here directly since this route runs the :api
  #     pipeline, not a reader pipeline that already mounts that plug.
  # Set on BOTH the success and not-found arms — a 404 can still be cached or
  # leak a referrer same as a 200, and the token is in the URL on the refused
  # request too.
  @doc "GET /sp/:token — resolve a preview link and serve the one document it names."
  def show(conn, %{"token" => token}) do
    conn = put_hardening_headers(conn)

    with {:ok, link} <- PreviewLinks.resolve(token),
         {:ok, doc} <-
           Content.get_document(link.doc_id, link.ref_type, link.dataset, scope(link)) do
      schema =
        case Content.Schema.get_schema_for_redaction(link.ref_type, link.dataset, scope(link)) do
          {:ok, s} -> s
          _ -> nil
        end

      json(conn, Envelope.render(doc, schema, CallerContext.from_conn(conn)))
    else
      _ -> not_found(conn)
    end
  end

  # ── ADMIN management ──────────────────────────────────────────────────────

  @doc "POST /v1/shares/preview-links — mint a preview link (raw token shown ONCE)."
  def mint(conn, params) do
    with {:ok, {ws, proj, dataset}} <- scope_triple(params["scope"]),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         :ok <- ensure_workspace_admin(conn, workspace.id),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws, proj),
         {:ok, doc_id, ref_type} <- doc_ref(params),
         :ok <- ensure_doc_exists(doc_id, ref_type, dataset, workspace, project) do
      attrs = %{
        workspace_id: workspace.id,
        project_id: project.id,
        dataset: dataset,
        doc_id: doc_id,
        ref_type: ref_type,
        label: params["label"],
        ttl: parse_ttl(params["ttl"])
      }

      case PreviewLinks.create(attrs) do
        {:ok, {raw, link}} ->
          conn
          |> put_status(:created)
          |> json(%{token: raw, url: preview_url(raw), link: link_json(link)})

        {:error, _changeset} ->
          unprocessable(conn, "could not create preview link")
      end
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, msg} when is_binary(msg) ->
        unprocessable(conn, msg)

      _ ->
        unprocessable(conn, "scope, ref_type, doc_id are required")
    end
  end

  @doc "GET /v1/shares/preview-links?scope=&ref_type=&doc_id= — list a document's preview links."
  def list(conn, params) do
    with {:ok, {ws, proj, dataset}} <- scope_triple(params["scope"]),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         :ok <- ensure_workspace_admin(conn, workspace.id),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws, proj),
         {:ok, doc_id, _ref_type} <- doc_ref(params) do
      links =
        PreviewLinks.list_for(workspace.id, project.id, dataset, doc_id)
        |> Enum.map(&link_json/1)

      json(conn, %{links: links})
    else
      {:error, :forbidden} ->
        forbidden(conn)

      _ ->
        unprocessable(conn, "scope, ref_type, doc_id are required")
    end
  end

  @doc "DELETE /v1/shares/preview-links/:id — revoke one preview link."
  def revoke(conn, %{"id" => id}) do
    case PreviewLinks.revoke_scoped(conn.assigns[:api_token], id) do
      {:ok, revoked} ->
        json(conn, %{
          revoked: not is_nil(revoked.revoked_at),
          id: revoked.id,
          revoked_at: revoked.revoked_at
        })

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp put_hardening_headers(conn) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-robots-tag", "noindex")
  end

  defp scope(link), do: [workspace_id: link.workspace_id, project_id: link.project_id]

  defp scope_triple(scope) when is_binary(scope), do: Sharing.scope_triple(scope)
  defp scope_triple(_), do: {:error, "scope is required (ws[/project[/dataset]])"}

  # Deliberately NO `published_ref_id/1` call — the raw id (drafts. prefix
  # included) is exactly what this feature persists and later resolves.
  defp doc_ref(%{"ref_type" => rt, "doc_id" => doc_id})
       when is_binary(rt) and rt != "" and is_binary(doc_id) and doc_id != "",
       do: {:ok, doc_id, rt}

  defp doc_ref(_), do: {:error, "ref_type and doc_id are required"}

  defp ensure_workspace_admin(conn, workspace_id) do
    if PreviewLinks.workspace_admin?(conn.assigns[:api_token], workspace_id),
      do: :ok,
      else: {:error, :forbidden}
  end

  # Existence check against the id AS GIVEN — a draft id resolves iff the
  # caller already has access to the draft, since `opts` here carries only
  # the target workspace/project (the same confinement `ensure_item_exists`
  # applies for ShareLink's published-only check).
  defp ensure_doc_exists(doc_id, ref_type, dataset, ws, proj) do
    case Content.get_document(doc_id, ref_type, dataset, workspace_id: ws.id, project_id: proj.id) do
      {:ok, _} -> :ok
      _ -> {:error, "no such document in this scope"}
    end
  end

  defp parse_ttl(t) when is_integer(t) and t > 0, do: t

  defp parse_ttl(t) when is_binary(t) do
    case Integer.parse(t) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_ttl(_), do: nil

  defp link_json(link) do
    %{
      id: link.id,
      doc_id: link.doc_id,
      ref_type: link.ref_type,
      dataset: link.dataset,
      label: link.label,
      # NO `url:` key, same reasoning as ShareLink's link_json/1 — only the
      # digest is stored, so a LISTED row cannot reconstruct the URL. The
      # mint 201 is the one place it is returned.
      expires_at: link.expires_at,
      revoked_at: link.revoked_at,
      inserted_at: Map.get(link, :inserted_at)
    }
  end

  defp preview_url(token), do: "#{Sharing.share_link_base() || ""}/sp/#{token}"

  defp forbidden(conn),
    do: ErrorResponse.emit(conn, {:error, :forbidden}, "workspace access required")

  defp unprocessable(conn, msg),
    do: ErrorResponse.emit_custom(conn, 422, "validation_failed", msg)

  defp not_found(conn),
    do: ErrorResponse.emit(conn, {:error, :not_found}, "preview link not found or expired")
end
