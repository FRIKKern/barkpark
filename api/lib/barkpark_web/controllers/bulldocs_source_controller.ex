defmodule BarkparkWeb.BulldocsSourceController do
  @moduledoc """
  Capability-bound canonical source for the embedded Paper readers.

  The endpoint is mounted beside each public/scoped Paper route and therefore
  inherits that route's membership/share boundary. It never exposes the broad
  document API to browser code and returns only the visibility-redacted source
  needed by the TUI/email mirrors.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Bpml

  def show(conn, %{"slug" => slug} = params) do
    dataset = Map.get(params, "dataset") || Content.paper_default_dataset()
    scope = paper_scope(conn, params)
    perspective = BarkparkWeb.AnonPerspective.resolve(conn, params)
    format = Map.get(params, "format", "json")

    cond do
      format not in ["json", "bpml"] ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          "error" => %{
            "code" => "unknown_format",
            "message" => "unknown format #{inspect(format)}",
            "hint" =>
              "formats: json (default, the block truth) and bpml (the readable isomorphic view); derived formats (html) have their own endpoints"
          }
        })

      true ->
        show_paper(conn, slug, dataset, scope, perspective, format)
    end
  end

  defp show_paper(conn, slug, dataset, scope, perspective, format) do
    case fetch_paper(slug, dataset, scope, perspective) do
      nil ->
        send_resp(conn, 404, "not found")

      paper ->
        source =
          case Content.Papers.reader_source(paper, dataset, scope) do
            {:blocks, blocks} ->
              resolved =
                Content.Papers.resolve_tasks_in_blocks(blocks, task_scope(paper), dataset)

              %{"kind" => "blocks", "blocks" => resolved}

            {:html, html} ->
              %{"kind" => "html", "html" => html}

            {:error, reason} ->
              {:error, reason}
          end

        case {source, format} do
          {{:error, reason}, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{"error" => %{"code" => to_string(reason)}})

          # BPML is a VIEW of blocks only — an html-source paper has no block
          # truth to print, so the isomorphic format honestly refuses.
          {%{"kind" => "blocks", "blocks" => blocks}, "bpml"} ->
            send_bpml(conn, paper, blocks)

          {%{"kind" => "html"}, "bpml"} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              "error" => %{
                "code" => "bpml_unavailable",
                "message" =>
                  "this paper was ingested as opaque body_html — it has no block source",
                "hint" => "re-ingest with blocks (or BPML) to make the isomorphic view available"
              }
            })

          {source, _json} ->
            json(conn, %{
              "id" => paper.doc_id,
              "title" => paper.title,
              "_rev" => paper.rev,
              "source" => source
            })
        end
    end
  end

  # The readable isomorphic view: a complete, self-describing <paper> document
  # as text, with the rev in a header so a working-copy pull can anchor on it.
  # The header carries the PAPER-LEVEL integer rev (content["rev"]) — the value
  # the ops path's if_rev guard compares against — NOT the row's _rev hash
  # (which the JSON envelope already exposes as "_rev").
  defp send_bpml(conn, paper, blocks) do
    bpml = Bpml.print_paper(%{"slug" => paper.doc_id, "title" => paper.title, "blocks" => blocks})

    conn
    |> put_resp_content_type("text/bpml")
    |> put_resp_header("x-paper-rev", to_string(paper_op_rev(paper)))
    |> send_resp(200, bpml)
  rescue
    e in ArgumentError ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        "error" => %{
          "code" => "bpml_unprintable",
          "message" => Exception.message(e),
          "hint" =>
            "this paper uses a block type outside the BPML kernel vocabulary; fetch format=json"
        }
      })
  end

  # The op-anchor rev: the integer content["rev"] the if_rev guard reads,
  # falling back to the row hash for legacy papers that never carried one.
  defp paper_op_rev(paper) do
    case get_in(paper.content || %{}, ["rev"]) do
      rev when is_integer(rev) -> rev
      _ -> paper.rev
    end
  end

  defp paper_scope(conn, %{"workspace_slug" => _}),
    do: BarkparkWeb.ScopeHelpers.scope_opts(conn)

  defp paper_scope(_conn, _params), do: []

  # Flat public readers are always published-only; AnonPerspective already
  # pins them, and get_public_paper keeps the Default-workspace boundary.
  defp fetch_paper(slug, dataset, [], :published),
    do: fetch_published(slug, dataset, [])

  defp fetch_paper(slug, dataset, [], perspective) do
    case public_scope() do
      nil -> nil
      scope -> fetch_paper(slug, dataset, scope, perspective)
    end
  end

  # Drafts is an overlay: prefer drafts.<published-id>, then fall back to the
  # published row. Raw addresses the exact id the caller supplied.
  defp fetch_paper(slug, dataset, scope, :drafts) do
    published_id = Content.published_id(slug)

    fetch_exact("drafts." <> published_id, dataset, scope) ||
      fetch_exact(published_id, dataset, scope)
  end

  defp fetch_paper(slug, dataset, scope, :raw), do: fetch_exact(slug, dataset, scope)
  defp fetch_paper(slug, dataset, scope, :published), do: fetch_published(slug, dataset, scope)

  defp fetch_published("drafts." <> _slug, _dataset, _scope), do: nil
  defp fetch_published(slug, dataset, []), do: Content.get_public_paper(slug, dataset)
  defp fetch_published(slug, dataset, scope), do: fetch_exact(slug, dataset, scope)

  defp fetch_exact(slug, dataset, scope), do: Content.get_paper(slug, dataset, scope)

  defp public_scope do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: id} -> [workspace_id: id]
      _ -> nil
    end
  end

  defp task_scope(paper) do
    ws_id =
      paper.workspace_id ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    [workspace_id: ws_id, project_id: paper.project_id]
  end
end
