defmodule BarkparkWeb.Plugs.PaperRevisionHeaders do
  @moduledoc "Pins successful scoped Paper reader responses to one released revision and content digest."

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Barkpark.Content.Document
  alias Barkpark.EpicFleet
  alias Barkpark.Repo

  def init(opts), do: opts

  def call(
        %Plug.Conn{
          path_info: ["w", _workspace, "p", _project, "papers", slug],
          assigns: %{current_workspace: workspace, current_project: project}
        } = conn,
        _opts
      ) do
    paper =
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

    case paper do
      %{released_revision_id: revision, content: content} when is_binary(revision) ->
        conn
        |> put_resp_header("etag", ~s("sha256:#{EpicFleet.canonical_digest(content)}"))
        |> put_resp_header("x-barkpark-paper-revision", revision)

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
