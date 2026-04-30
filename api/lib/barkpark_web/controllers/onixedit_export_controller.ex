defmodule BarkparkWeb.OnixeditExportController do
  @moduledoc """
  WI6 — HTTP endpoint that streams a single book document as ONIX 3.0 XML.

      GET /v1/plugins/onixedit/export/:dataset/:id.onix

  Mounted under the same `:require_admin` pipeline as `/v1/schemas/*`. Loads
  the document by id from the given dataset (preferring the latest draft over
  the published variant — same selection precedence as the BookEditor live
  view), enforces `_type == "book"`, then delegates to
  `Barkpark.Plugins.OnixEdit.Export.to_iodata/1` for the XSD-gated render.
  """

  use BarkparkWeb, :controller
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Repo

  @content_type "application/onix+xml"

  def show(conn, %{"dataset" => dataset, "id" => raw_id}) do
    pub_id = raw_id |> strip_onix_suffix() |> Content.published_id()
    draft_id = Content.draft_id(pub_id)

    case load_doc(dataset, pub_id, draft_id) do
      nil ->
        send_404(conn)

      %Document{type: type} = _doc when type != "book" ->
        send_400(conn, "expected _type=book, got _type=#{inspect(type)}")

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
        conn
        |> put_status(500)
        |> json(%{error: %{type: "xsd_invalid", reasons: reasons}})
    end
  end

  defp load_doc(dataset, pub_id, draft_id) do
    Document
    |> where([d], d.dataset == ^dataset and d.doc_id in ^[draft_id, pub_id])
    |> order_by([d],
      desc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 0 ELSE 1 END", d.doc_id)
    )
    |> limit(1)
    |> Repo.one()
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
    conn
    |> put_status(404)
    |> json(%{error: %{type: "not_found", message: "document not found"}})
  end

  defp send_400(conn, message) do
    conn
    |> put_status(400)
    |> json(%{error: %{type: "bad_request", message: message}})
  end
end
