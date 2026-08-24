defmodule Barkpark.Plugins.OnixEdit.Web.ExportController do
  @moduledoc """
  WI6 — HTTP endpoint that streams a single book document as ONIX 3.0 XML.

      GET /v1/plugins/onixedit/export/:dataset/:id.onix

  Mounted under the host's `:require_admin` pipeline via OnixEdit's
  `register_routes/1` callback — picked up by the host router's
  `plugin_routes(scope: :api)` callsite inside the `scope "/v1/plugins"`
  block. Loads the document by id from the given dataset (preferring the
  latest draft over the published variant — same selection precedence used
  by `Plugins.OnixEdit.Actions.publish_to_bokbasen/3` and, historically, by
  the removed BookEditor LV), enforces `_type == "book"`, then delegates
  to `Barkpark.Plugins.OnixEdit.Export.to_iodata/1` for the XSD-gated
  render.

  Goal `barkpark-G3` s5 — relocated from the host's now-deleted
  `BarkparkWeb.OnixeditExportController` module into the plugin
  namespace. The URL pattern is preserved exactly — the inlined host
  scope at `/v1/plugins/onixedit` was deleted in the same change.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Export
  alias BarkparkWeb.ErrorResponse

  @content_type "application/onix+xml"

  def show(conn, %{"dataset" => dataset, "id" => raw_id}) do
    pub_id = raw_id |> strip_onix_suffix() |> Content.published_id()
    draft_id = Content.draft_id(pub_id)

    case load_doc(conn, dataset, pub_id, draft_id) do
      nil ->
        send_404(conn)

      %Document{} = doc ->
        render_onix(conn, doc, pub_id)
    end
  end

  defp render_onix(conn, doc, pub_id) do
    case Export.to_iodata(book_doc_from(doc, pub_id)) do
      {:ok, iodata} ->
        conn
        |> put_resp_content_type(@content_type)
        |> put_resp_header("content-disposition", ~s|attachment; filename="#{pub_id}.onix"|)
        |> send_resp(200, iodata)

      {:error, {:xsd_invalid, reasons}} ->
        ErrorResponse.emit_custom(
          conn,
          500,
          "xsd_invalid",
          "the rendered ONIX did not validate against the 3.0 schema",
          %{reasons: reasons}
        )

      # A valid-but-unseeded (or non-string) ONIX codelist code. The document
      # is structurally fine — it just references a code our export maps don't
      # cover — so this is the caller's problem, not a server fault: 422 with a
      # structured body naming the offending codelist + code, never a bare 500.
      {:error, {:invalid_code, detail}} ->
        ErrorResponse.emit_custom(
          conn,
          422,
          "invalid_onix_code",
          detail["message"] || "the document references an ONIX code this export cannot map",
          %{codelist: detail["codelist"], onix_code: detail["code"]}
        )
    end
  end

  # Scoped lookup via the standard `Content.get_document` seam, which applies
  # both the dataset filter AND the workspace/project envelope from
  # `scope_opts(conn)` — the Default scope on the flat `:api` route (via
  # `AssignDefaultScope`) or the resolved tenant on the `/w/:ws/p/:project`
  # mirror (via `ResolveWorkspace`/`ResolveProject`). Replaces the previous
  # bare `dataset == ^dataset` query that ignored the tenant boundary and let
  # any admin token export another workspace's catalog by URL.
  #
  # The draft-preferred-over-published precedence is preserved by probing the
  # draft id first; each probe is independently scoped, so a cross-workspace
  # book never resolves on either id.
  defp load_doc(conn, dataset, pub_id, draft_id) do
    scope = scope_opts(conn)

    with {:error, :not_found} <- Content.get_document(draft_id, "book", dataset, scope),
         {:error, :not_found} <- Content.get_document(pub_id, "book", dataset, scope) do
      nil
    else
      {:ok, %Document{} = doc} -> doc
    end
  end

  defp book_doc_from(%Document{} = doc, pub_id) do
    (doc.content || %{})
    |> Map.put("_id", doc.doc_id)
    |> Map.put("_publishedId", pub_id)
    |> Map.put("_type", doc.type)
  end

  defp strip_onix_suffix(id) when is_binary(id) do
    case String.split(id, ".onix", parts: 2) do
      [base, ""] -> base
      _ -> id
    end
  end

  defp send_404(conn) do
    ErrorResponse.emit(conn, {:error, :not_found})
  end
end
