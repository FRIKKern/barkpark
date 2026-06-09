defmodule BarkparkWeb.ShareLinkController do
  @moduledoc """
  ITEM share links (P7) — Google-Docs-style direct links to ONE item.

    * `GET /s/:token` — PUBLIC. Resolves the opaque link and serves that single
      item, scoped to the LINK's own workspace/project/dataset (NOT the request
      path), so it is independent of any section share. A paper renders its
      reader page; another doc returns its published data; media serves the file.
    * `POST/GET/DELETE /v1/shares/links` — ADMIN. Mint (raw token shown once),
      list an item's links, revoke one.

  Read links serve PUBLISHED data only (the ref is a published id; drafts.* is
  never resolved), mirroring section read shares.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Content, Media, Tenancy}
  alias Barkpark.Content.Envelope
  alias Barkpark.Sharing
  alias Barkpark.Sharing.{Links, ShareLink}

  # ── PUBLIC resolver ──────────────────────────────────────────────────────

  def show(conn, %{"token" => token}) do
    case Links.resolve(token) do
      {:ok, link} -> serve(conn, link)
      {:error, _} -> not_found_html(conn)
    end
  end

  defp serve(conn, %ShareLink{kind: "doc", ref_type: "paper"} = link) do
    case Content.get_paper(link.ref_id, link.dataset, scope(link)) do
      %Content.Document{} = paper ->
        conn
        |> put_root_layout(html: {BarkparkWeb.Layouts, :bulldocs})
        |> put_layout(false)
        |> put_view(BarkparkWeb.ScopedPaperHTML)
        |> render(:show,
          article?: paper_article?(paper),
          body_html: paper_body_html(paper),
          slug: link.ref_id
        )

      _ ->
        not_found_html(conn)
    end
  end

  defp serve(conn, %ShareLink{kind: "doc"} = link) do
    case Content.get_document(link.ref_id, link.ref_type, link.dataset, scope(link)) do
      {:ok, doc} -> json(conn, Envelope.render(doc))
      _ -> not_found_json(conn)
    end
  end

  defp serve(conn, %ShareLink{kind: "media"} = link) do
    case Media.get_file(link.ref_id, scope(link)) do
      {:ok, file} ->
        full = Media.file_path(file.path)

        if File.exists?(full) do
          conn
          |> put_resp_content_type(file.mime_type || "application/octet-stream")
          |> send_file(200, full)
        else
          not_found_json(conn)
        end

      _ ->
        not_found_json(conn)
    end
  end

  # ── ADMIN management ──────────────────────────────────────────────────────

  @doc "POST /v1/shares/links — mint an item link (raw token shown ONCE)."
  def mint(conn, params) do
    with {:ok, {ws, proj, dataset}} <- scope_triple(params["scope"]),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws, proj),
         {:ok, kind, ref_type, ref_id} <- item_ref(params),
         access <- access_of(params),
         :ok <- ensure_item_exists(kind, ref_type, ref_id, dataset, workspace, project) do
      attrs = %{
        workspace_id: workspace.id,
        project_id: project.id,
        dataset: dataset,
        kind: kind,
        ref_type: ref_type,
        ref_id: ref_id,
        access: access,
        label: params["label"],
        ttl: parse_ttl(params["ttl"])
      }

      case Links.create(attrs) do
        {:ok, {raw, link}} ->
          conn
          |> put_status(:created)
          |> json(%{token: raw, url: "/s/#{raw}", link: link_json(link)})

        {:error, _changeset} ->
          unprocessable(conn, "could not create link")
      end
    else
      {:error, msg} when is_binary(msg) ->
        unprocessable(conn, msg)

      _ ->
        unprocessable(conn, "scope, kind (doc|media), ref_id (+ ref_type for docs) are required")
    end
  end

  @doc "GET /v1/shares/links?scope=&kind=&ref_type=&ref_id= — list an item's links."
  def list(conn, params) do
    with {:ok, {ws, proj, _dataset}} <- scope_triple(params["scope"]),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         %Tenancy.Project{} <- Tenancy.get_project(ws, proj),
         {:ok, kind, ref_type, ref_id} <- item_ref(params) do
      links = Links.list_for(workspace.id, kind, ref_type, ref_id) |> Enum.map(&link_json/1)
      json(conn, %{links: links})
    else
      _ -> unprocessable(conn, "scope, kind, ref_id (+ ref_type for docs) are required")
    end
  end

  @doc "DELETE /v1/shares/links/:id — revoke one link."
  def revoke(conn, %{"id" => id}) do
    case Links.revoke(id) do
      {:ok, _} -> json(conn, %{revoked: true, id: id})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "link not found"})
      _ -> unprocessable(conn, "could not revoke link")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp scope(link), do: [workspace_id: link.workspace_id, project_id: link.project_id]

  defp scope_triple(scope) when is_binary(scope), do: Sharing.scope_triple(scope)
  defp scope_triple(_), do: {:error, "scope is required (ws[/project[/dataset]])"}

  # kind=doc needs ref_type + ref_id; kind=media needs ref_id only.
  defp item_ref(%{"kind" => "media", "ref_id" => ref_id}) when is_binary(ref_id) and ref_id != "",
    do: {:ok, "media", nil, ref_id}

  defp item_ref(%{"kind" => "doc", "ref_type" => rt, "ref_id" => ref_id})
       when is_binary(rt) and rt != "" and is_binary(ref_id) and ref_id != "",
       do: {:ok, "doc", rt, ref_id}

  defp item_ref(_), do: {:error, "kind must be doc (with ref_type) or media, plus ref_id"}

  defp access_of(%{"access" => "edit"}), do: "edit"
  defp access_of(_), do: "read"

  defp ensure_item_exists("doc", "paper", ref_id, dataset, ws, proj) do
    case Content.get_paper(ref_id, dataset, workspace_id: ws.id, project_id: proj.id) do
      %Content.Document{} -> :ok
      _ -> {:error, "no such paper in this scope"}
    end
  end

  defp ensure_item_exists("doc", ref_type, ref_id, dataset, ws, proj) do
    case Content.get_document(ref_id, ref_type, dataset, workspace_id: ws.id, project_id: proj.id) do
      {:ok, _} -> :ok
      _ -> {:error, "no such document in this scope"}
    end
  end

  defp ensure_item_exists("media", _rt, ref_id, _dataset, ws, proj) do
    case Media.get_file(ref_id, workspace_id: ws.id, project_id: proj.id) do
      {:ok, _} -> :ok
      _ -> {:error, "no such media file in this scope"}
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

  defp link_json(%ShareLink{} = l) do
    %{
      id: l.id,
      kind: l.kind,
      ref_type: l.ref_type,
      ref_id: l.ref_id,
      access: l.access,
      dataset: l.dataset,
      label: l.label,
      # the STABLE, re-copyable link (P7 UX). Present whenever the raw token was
      # stored; `token_hash` (the secret-at-rest digest) is never exposed.
      url: l.token && "/s/#{l.token}",
      expires_at: l.expires_at,
      revoked_at: l.revoked_at,
      inserted_at: Map.get(l, :inserted_at)
    }
  end

  defp paper_body_html(%{content: content}), do: Map.get(content || %{}, "body_html") || ""
  defp paper_article?(%{content: content}), do: Map.get(content || %{}, "style") == "article"

  defp unprocessable(conn, msg),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: msg})

  defp not_found_json(conn),
    do: conn |> put_status(:not_found) |> json(%{error: "link not found or expired"})

  defp not_found_html(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(BarkparkWeb.ErrorHTML)
    |> render(:"404")
  end
end
