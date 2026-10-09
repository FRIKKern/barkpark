defmodule BarkparkWeb.Plugs.PreviewToken do
  @moduledoc """
  Verifies a short-lived preview JWT from `Authorization: Preview <jwt>`
  or `?preview_token=<jwt>`. Forces perspective to drafts on success.

  ## What a token may read (owner ruling #17, task-8bac87cd4b34aeb6)

  * `doc_ids` — when the claim lists any ids, the token reads those documents
    and nothing else: `GET …/doc/:dataset/:type/:doc_id` must name a listed id
    (a `drafts.` prefix on either side is ignored), `GET …/query/:dataset/:type`
    returns only listed documents (`ScopeHelpers` threads `:only_doc_ids`), and
    the backlinks / related / tags reads and `?expand=` are refused, because
    each returns documents the token does not name. An empty or absent list
    keeps the dataset-wide behaviour existing integrations rely on.
    `GET /v1/preview/listen/:dataset` (task-78dc25a4f117fa07) is ALSO allowed
    with a non-empty list — the SSE/listen route carries neither `:doc_id` nor
    `:type` in its path, so it needs its own `listen_route?/1` match below; the
    per-event fence for what a doc-scoped token's stream actually forwards
    lives in `BarkparkWeb.ListenFilter`'s `only_doc_ids`.
  * `workspace_id` (optional) — reads run in that workspace instead of the
    Default workspace; `project_id` (optional) narrows to one of its projects.
    A workspace or project the box does not have is refused.

  Every refusal happens before the JTI is recorded, so a token aimed at the
  wrong document is not burned. Refusals are 403 `forbidden` with reason
  `preview_scope`.

  ## Single-use, unless `multi_use` (task-8f7cba7f65cb343c)

  `record_jti/1` is single-use by construction (`INSERT … ON CONFLICT DO
  NOTHING` on `jti`): the first request to verify a given token wins, every
  later one gets `{:error, :already_used}`. A token signed with `multi_use:
  true` — a claim that can ONLY originate from `PreviewTokenController.mint/2`,
  since it rides inside the signed payload — skips that call here instead:
  its jti was already registered once, at mint time, so `revoke/1` /
  `revoked?/1` (checked on every `verify/2` call regardless of `multi_use`)
  and `sweep`/`sweep_batch` GC still have a row to act on, but no request
  ever burns it. TTL (clamped to a hard max by the mint route) and revocation
  are what bound a `multi_use` token instead of single-use's one-shot burn.
  """

  import Plug.Conn

  alias Barkpark.Content.{DraftId, Errors}
  alias Barkpark.PreviewToken
  alias Barkpark.Tenancy

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = Application.get_env(:barkpark, :preview, [])[:secret]

    with raw when is_binary(raw) <- extract_token(conn),
         true <- is_binary(secret) and byte_size(secret) > 0,
         {:ok, claims} <- PreviewToken.verify(raw, secret),
         :ok <- check_dataset_scope(conn, claims),
         # A token without a dataset claim is structurally unusable (401 via
         # record_jti's contract); refuse it before judging what it names.
         true <- is_binary(Map.get(claims, "dataset")),
         {:ok, doc_ids} <- check_doc_scope(conn, claims),
         {:ok, conn} <- assign_claimed_scope(conn, claims),
         {:ok, _} <- maybe_record_jti(claims) do
      conn
      |> assign(:preview_claims, claims)
      |> assign(:forced_perspective, "drafts")
      |> maybe_assign_doc_ids(doc_ids)
    else
      {:error, :already_used} -> deny(conn, :replay)
      {:error, :dataset_mismatch} -> deny(conn, :forbidden)
      {:error, :preview_scope} -> deny(conn, :preview_scope)
      _ -> deny(conn, :unauthorized)
    end
  end

  # The token's document list, as published ids. `[]` = dataset-wide.
  # task-8f7cba7f65cb343c — a `multi_use` token was already registered once,
  # at mint time (`PreviewTokenController.mint/2`), so calling `record_jti`
  # here on every read would ALWAYS hit the existing row and refuse every
  # request past the first with `:already_used` — exactly the single-use
  # behaviour this claim exists to opt out of. `revoked?/1` is still checked
  # on every call, inside `PreviewToken.verify/2` above, regardless of
  # `multi_use` — a revoked multi_use token is refused immediately, same as
  # any other revoked token.
  defp maybe_record_jti(%{"multi_use" => true} = claims), do: {:ok, claims}
  defp maybe_record_jti(claims), do: PreviewToken.record_jti(claims)

  defp claimed_doc_ids(claims) do
    case Map.get(claims, "doc_ids") do
      ids when is_list(ids) ->
        ids
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.map(&DraftId.published_id/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # A token that names documents reads only those (see the moduledoc).
  defp check_doc_scope(conn, claims) do
    case claimed_doc_ids(claims) do
      [] ->
        {:ok, []}

      ids ->
        params = conn.path_params
        conn = fetch_query_params(conn)

        cond do
          Map.has_key?(conn.query_params, "expand") ->
            {:error, :preview_scope}

          is_binary(params["doc_id"]) ->
            if DraftId.published_id(params["doc_id"]) in ids,
              do: {:ok, ids},
              else: {:error, :preview_scope}

          is_binary(params["type"]) ->
            {:ok, ids}

          # task-78dc25a4f117fa07: GET /v1/preview/listen/:dataset carries
          # neither `:doc_id` nor `:type` in its path — a dataset-only shape
          # none of the arms above recognise. Matched by EXACT path_info,
          # not by "no doc_id and no type", so a future preview route that
          # also lacks those params does not silently fall into this arm —
          # it stays {:error, :preview_scope} until it is named here too.
          # The per-event doc_id fence for what this token actually streams
          # lives downstream, in ListenFilter's only_doc_ids (listen_filter.ex).
          listen_route?(conn) ->
            {:ok, ids}

          true ->
            {:error, :preview_scope}
        end
    end
  end

  defp listen_route?(%{path_info: ["v1", "preview", "listen", _dataset]}), do: true
  defp listen_route?(_), do: false

  defp maybe_assign_doc_ids(conn, []), do: conn
  defp maybe_assign_doc_ids(conn, ids), do: assign(conn, :preview_doc_ids, ids)

  # Optional `workspace_id` / `project_id` claims seat the read in that tenant.
  # `AssignDefaultScope` runs after this plug and leaves an existing assign
  # alone, so a token without the claim keeps reading the Default workspace.
  defp assign_claimed_scope(conn, claims) do
    case Map.get(claims, "workspace_id") do
      nil ->
        {:ok, conn}

      ws_id when is_binary(ws_id) ->
        case Tenancy.get_workspace_by_id(ws_id) do
          %{id: id} = ws ->
            assign_claimed_project(assign(conn, :current_workspace, ws), id, claims)

          nil ->
            {:error, :preview_scope}
        end

      _ ->
        {:error, :preview_scope}
    end
  end

  defp assign_claimed_project(conn, ws_id, claims) do
    case Map.get(claims, "project_id") do
      nil ->
        {:ok, conn}

      p_id when is_binary(p_id) ->
        case Tenancy.get_project_by_id(p_id) do
          %{workspace_id: ^ws_id} = project -> {:ok, assign(conn, :current_project, project)}
          _ -> {:error, :preview_scope}
        end

      _ ->
        {:error, :preview_scope}
    end
  end

  # Bind the token's `dataset` claim to the dataset the request actually reads.
  # Without this a token minted for one dataset (e.g. `production`) could read
  # drafts from ANY other dataset in the same workspace simply by typing that
  # dataset into the `/v1/preview/.../:dataset/...` path — cross-dataset draft
  # scope escalation. The check runs BEFORE `record_jti` so a wrong-dataset
  # attempt never consumes (burns) the JTI of an otherwise-legitimate token.
  #
  #   * claim carries no dataset  → :ok here; `record_jti` rejects it (:invalid
  #     → 401), preserving the pre-existing "missing dataset claim" contract.
  #   * route carries no :dataset → :ok (no such preview route today; keeps the
  #     plug route-agnostic rather than failing shapes it can't bind).
  #   * both present + differ     → {:error, :dataset_mismatch} → 403.
  defp check_dataset_scope(conn, claims) do
    route_ds = conn.path_params["dataset"]
    claim_ds = Map.get(claims, "dataset")

    cond do
      not is_binary(claim_ds) -> :ok
      not is_binary(route_ds) -> :ok
      claim_ds == route_ds -> :ok
      true -> {:error, :dataset_mismatch}
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Preview " <> jwt] ->
        jwt

      _ ->
        conn = fetch_query_params(conn)
        conn.query_params["preview_token"]
    end
  end

  defp deny(conn, reason) do
    env = Errors.to_envelope({:error, reason}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
