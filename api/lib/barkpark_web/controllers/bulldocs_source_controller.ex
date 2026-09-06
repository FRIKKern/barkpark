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
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  def show(conn, %{"slug" => slug} = params) do
    dataset = requested_dataset(params)
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
    case Content.Papers.op_rev(paper) do
      {:error, {:unreadable_rev, field}} ->
        rev_unreadable(conn, paper, field)

      {:ok, rev} ->
        bpml = Bpml.print_paper(Content.Papers.bpml_paper_map(paper, blocks))

        conn
        |> put_resp_content_type("text/bpml")
        |> put_resp_header("x-paper-rev", to_string(rev))
        |> send_resp(200, bpml)
    end
  rescue
    # The printer's ONE typed refusal, for ALL FOUR unprintable positions
    # (block, inline node, mark, table head cell). It used to rescue only
    # ArgumentError, so the three FunctionClauseError shapes escaped as raw HTTP
    # 500s with an HTML error page — 141 of 776 published papers on the
    # 2026-08-17 census. The message carries kind+type, so the census keeps
    # bucketing what still needs kernel coverage.
    e in UnprintableError ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        "error" => %{
          "code" => "bpml_unprintable",
          "message" => Exception.message(e),
          "hint" =>
            "this paper uses a #{e.kind} shape outside the BPML kernel vocabulary; fetch format=json"
        }
      })
  end

  # An UNREADABLE op-anchor is a failed READ, never a rev. Refusing here (rather
  # than serving some substitute) is what keeps the push side's precondition
  # from ever comparing against a value nobody could derive — the two sides read
  # `Content.Papers.op_rev/1`, the ONE owner, and refuse on the same input.
  defp rev_unreadable(conn, paper, field) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      "error" => %{
        "code" => "paper_rev_unreadable",
        "message" =>
          "cannot read the op-anchor rev of paper #{paper.doc_id}: #{field} is present but not an integer",
        "hint" =>
          "this paper's #{field} is corrupt; repair it before pulling or pushing a working copy"
      }
    })
  end

  # `/papers/:slug/source` takes `dataset` from the QUERY STRING (only the
  # sibling `/d/:dataset/papers/:slug/source` route carries it as a path
  # segment, where Phoenix's path params win the merge). `?dataset[]=x` decodes
  # to a list and `?dataset[a]=b` to a map; either one reaches
  # `x.dataset == ^dataset` on a :string column and raises Ecto.Query.CastError,
  # which has no Plug.Exception impl → a raw 500 instead of a 404. The dataset
  # is a scope selector with a documented default, so a malformed one fails soft
  # to that default (same guard shape as MetaController.show/2).
  #
  # The share gate is ALIGNED to this: `RequireShareScope.request_dataset/1`
  # resolves the dataset the same way, so an anonymous share reader is checked
  # against the dataset this function returns (task-4f26838232b5ece0).
  defp requested_dataset(params) do
    case Map.get(params, "dataset") do
      ds when is_binary(ds) -> ds
      _ -> Content.paper_default_dataset()
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
