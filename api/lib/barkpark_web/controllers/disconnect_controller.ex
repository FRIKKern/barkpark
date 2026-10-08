defmodule BarkparkWeb.DisconnectController do
  @moduledoc """
  `POST /v1/data/disconnect/:dataset/:doc_id` — remove every reference to a
  document from the documents that hold one, and say which documents and fields
  changed (task-0bc05ce5cdefd8dc). The HTTP twin of the LiveView unpublish
  guard's "Disconnect references and unpublish", which calls
  `Content.disconnect_references/3` in-process.

  The call rewrites OTHER documents, so it is for a full workspace member with
  write only: a grant-narrowed caller or a share-link edit token is refused
  (their write rights cover named documents, not every referencer).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Edges
  alias BarkparkWeb.ScopeHelpers

  action_fallback BarkparkWeb.FallbackController

  def create(conn, %{"dataset" => dataset, "doc_id" => doc_id}) do
    if narrowed?(conn.assigns) do
      {:error, :forbidden}
    else
      opts = ScopeHelpers.scope_opts(conn) ++ [source: :api]
      changed = Edges.referencing_fields(doc_id, dataset, opts)

      case Content.disconnect_references(doc_id, dataset, opts) do
        :ok -> json(conn, %{disconnected: changed})
        {:error, _} = err -> err
      end
    end
  end

  @doc false
  def narrowed?(assigns) do
    assigns[:grant_scoped_read] == true or assigns[:share_writer] == true or
      assigns[:share_public] == true
  end
end
