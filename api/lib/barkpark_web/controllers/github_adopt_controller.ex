defmodule BarkparkWeb.GithubAdoptController do
  @moduledoc """
  Adopt an intake task into Barkpark (design paper `bp-github-bridge-epic-charter`,
  Wave 4 — adoption). Mounted by the github plugin's `register_routes/1` on the
  `:token` bucket at `POST /v1/plugins/github/adopt/:id` — a bearer-gated
  OPERATOR action (NOT `:admin`), so `bp github adopt <task>` runs with a normal
  operator token.

  ## Contract (D6)

  `adopt/2` reads the `:id` path param (the `gh-<num>` task) and the optional
  `dataset` param (default `"production"`), then hands off to
  `Barkpark.Plugins.Github.Adopt.adopt/3`. That service strips `needs-human`,
  flips `content.github.state` `"intake" → "adopted"`, and posts a best-effort
  backlink — it NEVER auto-claims a worker (adoption clears the gate only; the
  operator claims the adopted task through the normal `bp task` path afterward).

  ## Status mapping

    * `{:ok, _doc}`            → `200 {ok: true, task: id, state: "adopted"}`
    * `{:ok, _doc, collapse}`  → `200 {ok: true, task: id, state: "adopted",
      collapse: %{published: false, error: <wall detail>}}` — adopted, but the
      draft-twin collapse publish was REJECTED by the authoring wall (D23). The
      adopt side effects are already committed (a 422-after-commit would lie),
      so HTTP stays `200`; the `collapse.error` carries the machine-readable
      wall `code` (`label_spine`/`unknown_tag`/`duplicate_of`) so the operator
      fixes the published task's labels and re-adopts.
    * `{:error, :not_intake}`  → `409` — the task exists but is not an adoptable
      intake (already adopted-and-re-hit returns `{:ok,_}`, so a `:not_intake`
      here is a plain/mirrored/detached task, an operator error, not transient)
    * `{:error, :not_found}`   → `404`
    * `{:error, _}`            → `422` — the ledger write failed

  ## Adopt seam

  `adopt/2` calls the service through a private seam so a controller test can
  assert dispatch + status mapping without a live adoption path (which would
  otherwise reach the real `Client.create_comment` backlink). Override with
  `config :barkpark, :github_adopt_fun, fun/3` in test (the webhook controller's
  `:github_webhook_intake_fun` precedent). Absent → the real Adopt module.
  """

  use BarkparkWeb, :controller

  alias BarkparkWeb.ErrorResponse

  # The 400 messages for a list/map-shaped param — see the NON-BINARY PARAM
  # GUARD comment on the guard clauses below.
  @non_binary_dataset_message "dataset must be a string; a list or map value " <>
                                "(e.g. ?dataset[]=x or ?dataset[k]=v) is not a dataset name"
  @non_binary_id_message "id must be a string; a list or map value is not a task id"

  @doc """
  Adopt the `:id` intake task. See the moduledoc for the status mapping.
  """
  # NON-BINARY PARAM GUARD (task-0fba128e04ab8aee). Neither mount — the flat
  # `/v1/plugins/github/adopt/:id` nor the scoped `/w/:ws/p/:proj/v1/plugins/…`
  # mirror — carries a `:dataset` path segment, so `dataset` is a
  # caller-controlled query param: `?dataset[]=x` parses to a LIST and
  # `?dataset[k]=v` to a MAP, and `Map.get/3`'s default never fires for a key
  # that IS present. Both shapes then reached
  # `Barkpark.Plugins.Github.Adopt.adopt/3`, whose only head is
  # `when is_binary(doc_id) and is_binary(dataset)` — FunctionClauseError after
  # dispatch, i.e. a 500 reachable by any write-tier bearer (this bucket's
  # `RequireWriteForMutation` gate is the only rung above `read`). This
  # controller has no `action_fallback`, so the raise went straight to the
  # endpoint's 500.
  #
  # The refusal is TWO CLAUSES ABOVE the real one, not a branch inside it, on
  # purpose: `scripts/pds-elixir-receipt-census.exs` fingerprints the `{head,
  # body}` of the def that ENCLOSES each success-receipt literal, so editing the
  # body of the clause that renders the adopt receipts — or moving them into a
  # helper — orphans the census register rows for
  # `GithubAdoptController.adopt/2` and leaves both routed arrivals undisposed.
  # Guarding at the head keeps that clause byte-identical and the register
  # honest. Do not spell the receipt literal in prose here either: the census
  # counts it textually, and a mention in a comment is a phantom that drifts the
  # baseline.
  #
  # `:id` is bound by the path segment and so is always a binary through today's
  # mounts; it is guarded anyway (Adopt.adopt/3 requires BOTH args to be
  # binaries) so the action is total for its own contract rather than resting on
  # a router invariant a future mount could change.
  def adopt(conn, %{"dataset" => dataset}) when not is_binary(dataset),
    do: ErrorResponse.emit(conn, {:error, :malformed}, @non_binary_dataset_message)

  def adopt(conn, %{"id" => id}) when not is_binary(id),
    do: ErrorResponse.emit(conn, {:error, :malformed}, @non_binary_id_message)

  def adopt(conn, %{"id" => id} = params) do
    dataset = Map.get(params, "dataset", "production")

    # Thread the resolved tenant scope (D15). On the scoped
    # `/w/:ws/p/:proj/v1/plugins/github/adopt/:id` mirror the ResolveWorkspace /
    # ResolveProject plugs have set `current_workspace` / `current_project`, so
    # `scope_opts/1` carries the real `workspace_id`/`project_id` into the Adopt
    # service (already scope-clean). On the flat back-compat mount the assigns
    # are absent and `scope_opts/1` yields the seeded-Default scope (nil-safe) —
    # today's behavior. The Adopt service NEVER reads tenancy from a request
    # param; scope arrives only through these server-authoritative assigns.
    opts = BarkparkWeb.ScopeHelpers.scope_opts(conn)

    case adopt_fun().(id, dataset, opts) do
      # Adopted, but the draft-twin collapse publish hit the authoring wall
      # (D23): side effects committed on the draft, so HTTP stays 200 — the
      # `collapse` field carries the machine-readable wall detail for a retry.
      {:ok, _doc, %{published: false} = collapse} ->
        json(conn, %{ok: true, task: id, state: "adopted", collapse: collapse})

      {:ok, _doc} ->
        json(conn, %{ok: true, task: id, state: "adopted"})

      {:error, :not_intake} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            code: "not_intake",
            message: "task is not a src:github intake awaiting adoption"
          }
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "no such task"}})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "adopt_failed", message: "could not adopt task"}})
    end
  end

  # Adopt seam: overridable in test via app env, else the real module. The
  # module is resolved dynamically so a build without the sibling Adopt module
  # present still compiles clean — the call resolves at request time, by which
  # point the module is loaded.
  defp adopt_fun do
    Application.get_env(:barkpark, :github_adopt_fun) || (&default_adopt/3)
  end

  defp default_adopt(id, dataset, opts) do
    mod = Module.concat(Barkpark.Plugins.Github, Adopt)
    mod.adopt(id, dataset, opts)
  end
end
