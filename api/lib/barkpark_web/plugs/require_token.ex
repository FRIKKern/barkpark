defmodule BarkparkWeb.Plugs.RequireToken do
  @moduledoc """
  Plug that verifies Bearer token and assigns token to conn.

  ## Share-token flat-route seal (wave-2, foreign-scope-share-token-flat-read)

  A scope-bound SHARE token (`share_scope` set — minted via
  `POST /v1/shares/tokens` / `Auth.create_share_token/5`, opaque
  `share-edit-<surface>` permissions) is refused with 403 on every FLAT route.
  Live-confirmed escape this closes: such a token is `kind: "api"`, so it
  counted as authed on the flat read routes (`GET /v1/data/doc/...`,
  `GET /api/documents/...`), skipped the anonymous drafts clamp, and read a
  DEFAULT-scoped draft — the flat routes derive scope from
  `AssignDefaultScope`, never from the token's `share_scope`, so the token
  escaped its scope binding entirely.

  The discriminator is `share_token_off_surface?/2`: router pipelines run
  after the route match, so `conn.path_params` is populated — a scoped route
  carries `"workspace_slug"`, a flat route does not. Every pipeline that
  legitimately serves a share token is scoped (`RequireShareEditToken` mounts
  only on `:scoped_mutate` / `:scoped_media_mutate`; `RequireShareScope`
  grants anonymously), and on scoped routes outside the token's exact scope
  the share machinery + `ResolveWorkspace`'s membership gate already fail
  closed. `BarkparkWeb.Plugs.OptionalToken` applies the same predicate.
  """

  import Plug.Conn
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Auth.verify_token(raw_token),
         false <- share_token_off_surface?(conn, token),
         {:dataset, false} <- {:dataset, dataset_off_binding?(conn, token)} do
      # Best-effort, throttled liveness stamp so operators can spot dead tokens.
      # Never blocks auth (errors are swallowed inside touch_last_used/1).
      _ = Auth.touch_last_used(token)
      assign(conn, :api_token, token)
    else
      # A VALID share token presented outside its share surface: forbidden,
      # not unauthorized — the credential verified, the surface is wrong.
      true -> deny(conn, {:error, :forbidden})
      {:dataset, true} -> deny(conn, {:error, :forbidden_dataset})
      _ -> deny(conn, {:error, :unauthorized})
    end
  end

  @doc """
  True when a DATASET-BOUND token (`dataset_bound: true`, set only when the
  mint request named `dataset`) is presented on a request for another dataset
  (task-4418b517649a58ce). The request's dataset is the `:dataset` path segment,
  else a `dataset` param; a request naming no dataset is not refused here.

  `dataset` alone binds nothing: it defaults to `"production"` on every row,
  so an unbound token (NULL — every row minted before the column) keeps its
  cross-dataset access within its workspace.

  Applied at every bearer door: here and in `OptionalToken` (flat and
  `:scoped_api`), and in `ResolveWorkspace`, which every `/w/:ws/p/:proj`
  pipeline runs after its credential is resolved — so a token that reached a
  scoped route through a session or `OptionalSessionToken` is fenced too.
  """
  @spec dataset_off_binding?(Plug.Conn.t(), ApiToken.t() | nil) :: boolean()
  def dataset_off_binding?(conn, %ApiToken{dataset_bound: true, dataset: bound}) do
    case requested_dataset(conn) do
      requested when is_binary(requested) -> requested != bound
      _ -> false
    end
  end

  def dataset_off_binding?(_conn, _token), do: false

  defp requested_dataset(conn) do
    case conn.path_params do
      %{"dataset" => dataset} -> dataset
      _ -> param_dataset(conn.params)
    end
  end

  # `conn.params` is `%Plug.Conn.Unfetched{}` before Plug.Parsers ran; that
  # struct carries no "dataset" key, so it falls to nil.
  defp param_dataset(%{"dataset" => dataset}), do: dataset
  defp param_dataset(_), do: nil

  @doc """
  True when a verified token is a scope-bound share token (`share_scope` set)
  presented on a FLAT (non-scoped) route — the one shape that must be refused
  at token resolution (see the moduledoc). Scoped routes (`/w/:workspace_slug/
  p/:project_slug/...`) keep serving the token so its own share pipelines
  (`RequireShareEditToken` / `RequireShareScope`) stay the authority there.

  Shared with `BarkparkWeb.Plugs.OptionalToken` so both token-resolving plugs
  refuse identically — one owner for the predicate.
  """
  @spec share_token_off_surface?(Plug.Conn.t(), ApiToken.t()) :: boolean()
  def share_token_off_surface?(conn, %ApiToken{share_scope: share_scope}) do
    is_binary(share_scope) and not is_binary(conn.path_params["workspace_slug"])
  end

  @doc false
  @spec deny(Plug.Conn.t(), {:error, atom()}) :: Plug.Conn.t()
  def deny(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope(reason, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
