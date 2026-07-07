defmodule Barkpark.Plugins.Github.Projects do
  @moduledoc """
  One-directional GitHub **Projects v2** projection for the `github` bridge
  (epic charter **D10**). Given a mirrored task and its issue, it paints the
  task's Status / Priority / Worker / Goal onto a configured Projects v2 board
  via GraphQL — a READ-ONLY executive dashboard that NOBODY edits back.

  ## Strictly outbound, diffed, gated (D10)

    * **Gated on `project_id`.** If `Settings.get_credentials()[:project_id]`
      is absent/blank, `sync/5` returns `:noop` IMMEDIATELY — zero GraphQL. This
      is the isolation gate: a board that isn't configured means the whole
      Projects path is inert and the proven Issues loop is 100% unaffected.

    * **Diffed to ZERO GraphQL when unchanged (the flagship invariant).** The
      desired field values are hashed into a `fingerprint`
      (`:erlang.phash2/1`). If the stored `projects_fingerprint` on the task's
      `content.github` link equals it, `sync/5` returns `:noop` and writes
      NOTHING. Only a changed fingerprint proceeds to any GraphQL call.

    * **One-directional (D5).** GraphQL/REST reads here (the issue's GraphQL
      node id, the board's field metadata) are used ONLY to WRITE the
      projection. No function in this module — or anywhere — reads a Projects
      field value BACK into a task field. The reverse writer does not exist.

  ## Desired field values

  The values come from the SAME task content the outbound issue labels come
  from (`Barkpark.Plugins.Github.Projection`), read via the ownership matrix
  (`Fields.matrix/0` entries whose `:projects_field` is non-nil):

    * `:status`   — the task `lifecycle_status` (mirrors the projection's
      status label derivation).
    * `:priority` — `content.priority`.
    * `:worker`   — `content.claim.worker` (falling back to `content.worker`).
    * `:goal`     — `content.parent_id`.

  A `nil` desired field is simply NOT written (leave it ABSENT, never fabricate).

  ## GraphQL sequence (only on a changed fingerprint)

    1. Resolve the issue's GraphQL node id via `Client.get_issue/3` (REST
       already returns `"node_id"` — no new REST verb needed).
    2. `addProjectV2ItemById(projectId, contentId: node_id)` → the board item
       id. Idempotent: re-adding an existing content item returns its id. A
       stored `projects_item_id` off the link lets a later sync SKIP the add.
    3. Query the board's fields ONCE, mapping each field NAME → its field id and
       (for a single-select) each option NAME → option id.
    4. Per non-nil desired field, `updateProjectV2ItemFieldValue` with
       `singleSelectOptionId` (Status/Priority/Worker single-selects — matched
       case-insensitively by option name) or `text` (Goal text field). An
       UNMATCHED option name or a missing field NAME on the board → log + skip
       that ONE field, never crash. Field/option names are operator-configured.

  On success `sync/5` returns `{:ok, %{fingerprint: fingerprint, item_id:
  item_id}}` so the wiring (slice 4) stamps `Link.put` with `projects_fingerprint`
  + `projects_item_id` (`source: "github"`, outbox-excluded — D4 cut #2). Any
  `Client` `{:error, _}` bubbles as `{:error, _}` — `sync/5` stays HONEST about
  failure; the WIRING is what swallows it (log + continue, failure-isolated), not
  this module.

  ## Client seam

  `Client` is reached through an injected seam so this module compiles and tests
  WITHOUT the slice-1 `Client.graphql/3`/`get_issue/3` transport in the tree:
  `opts[:client]` wins, then `Application.get_env(:barkpark, :github_client)`,
  then the real `Barkpark.Plugins.Github.Client`.
  """

  require Logger

  alias Barkpark.Plugins.Github.{Fields, Link, Settings}

  @default_client Barkpark.Plugins.Github.Client

  # projects_field atom → the board field's display NAME (matched
  # case-insensitively against the operator-configured board field names).
  @field_names %{status: "Status", priority: "Priority", worker: "Worker", goal: "Goal"}

  @add_item_mutation """
  mutation($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
      item { id }
    }
  }
  """

  @fields_query """
  query($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        fields(first: 50) {
          nodes {
            ... on ProjectV2SingleSelectField { id name options { id name } }
            ... on ProjectV2FieldCommon { id name }
          }
        }
      }
    }
  }
  """

  @update_single_select_mutation """
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(
      input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {singleSelectOptionId: $optionId}}
    ) {
      projectV2Item { id }
    }
  }
  """

  @update_text_mutation """
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $text: String!) {
    updateProjectV2ItemFieldValue(
      input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {text: $text}}
    ) {
      projectV2Item { id }
    }
  }
  """

  @typedoc "The pure desired-value map hashed into the diff fingerprint."
  @type desired :: %{status: term(), priority: term(), worker: term(), goal: term()}

  @doc """
  Paint a task's Status/Priority/Worker/Goal onto the configured Projects v2
  board. One-directional, `project_id`-gated, diffed to zero GraphQL when
  unchanged. See the moduledoc for the full contract.

  Returns:

    * `:noop` — the board is unconfigured (`project_id` blank) OR the stored
      fingerprint already matches (nothing changed). ZERO GraphQL either way.
    * `{:ok, %{fingerprint: term, item_id: String.t()}}` — the projection was
      (re)applied; the wiring stamps the fingerprint + item id back onto the link.
    * `{:error, term}` — a `Client` transport/GraphQL error bubbled up honestly.
  """
  # @canonical capability:github-projects-sync aka:projects_v2,project_field,dashboard,graphql doc:.claude/workflows/bp-github-bridge-epic-charter.md
  @spec sync(map(), String.t(), integer() | String.t(), map() | nil, keyword()) ::
          {:ok, %{fingerprint: term(), item_id: String.t()}} | :noop | {:error, term()}
  def sync(task_doc, repo, issue_number, link, opts \\ []) when is_binary(repo) do
    case project_id(opts) do
      nil ->
        :noop

      project_id ->
        link_map = link_map(link, task_doc)
        desired = desired_fields(task_doc)
        fp = :erlang.phash2(desired)

        if fp == link_map["projects_fingerprint"] do
          :noop
        else
          apply_projection(desired, fp, link_map, repo, issue_number, project_id, opts)
        end
    end
  end

  @doc """
  The pure desired-value map (`%{status:, priority:, worker:, goal:}`) derived
  from the task content via the ownership matrix. Exposed for the wiring/tests to
  compute the diff fingerprint deterministically. No side effects.
  """
  @spec desired_fields(map()) :: desired()
  def desired_fields(task_doc) do
    content = content_of(task_doc)

    Fields.all()
    |> Enum.reduce(%{}, fn {_field, entry}, acc ->
      case entry.projects_field do
        nil -> acc
        pf -> Map.put(acc, pf, value_for(pf, content))
      end
    end)
  end

  @doc """
  The diff fingerprint (`:erlang.phash2/1`) of a task's desired Projects field
  values — the exact value compared against the stored `projects_fingerprint`.
  Pure.
  """
  @spec fingerprint(map()) :: non_neg_integer()
  def fingerprint(task_doc), do: :erlang.phash2(desired_fields(task_doc))

  # ---------------------------------------------------------------------------
  # GraphQL sequence (only reached on a changed fingerprint)
  # ---------------------------------------------------------------------------

  defp apply_projection(desired, fp, link_map, repo, issue_number, project_id, opts) do
    with {:ok, item_id} <-
           resolve_item_id(link_map["projects_item_id"], repo, issue_number, project_id, opts),
         {:ok, index} <- fetch_field_index(project_id, opts),
         :ok <- write_fields(desired, index, project_id, item_id, opts) do
      {:ok, %{fingerprint: fp, item_id: item_id}}
    end
  end

  # A stored item id means the content is already on the board — skip the add
  # (and its issue GET). Otherwise resolve the issue's GraphQL node id and add it.
  defp resolve_item_id(item_id, _repo, _number, _project_id, _opts)
       when is_binary(item_id) and item_id != "" do
    {:ok, item_id}
  end

  defp resolve_item_id(_absent, repo, number, project_id, opts) do
    with {:ok, issue} <- client(opts).get_issue(repo, number, opts),
         node_id when is_binary(node_id) and node_id != "" <- node_id(issue),
         {:ok, data} <-
           client(opts).graphql(
             @add_item_mutation,
             %{"projectId" => project_id, "contentId" => node_id},
             opts
           ),
         item_id when is_binary(item_id) <- added_item_id(data) do
      {:ok, item_id}
    else
      {:error, _} = err -> err
      _ -> {:error, :projects_item_add_failed}
    end
  end

  defp fetch_field_index(project_id, opts) do
    with {:ok, data} <-
           client(opts).graphql(@fields_query, %{"projectId" => project_id}, opts) do
      {:ok, index_fields(data)}
    end
  end

  # Write each non-nil desired field. A missing board field NAME or an unmatched
  # single-select option → log + skip that ONE field (never crash, never error).
  # Only a real Client {:error, _} halts and bubbles.
  defp write_fields(desired, index, project_id, item_id, opts) do
    desired
    |> Enum.reject(fn {_pf, value} -> is_nil(value) end)
    |> Enum.reduce_while(:ok, fn {pf, value}, _acc ->
      case write_field(pf, value, index, project_id, item_id, opts) do
        {:error, _} = err -> {:halt, err}
        _ok_or_skip -> {:cont, :ok}
      end
    end)
  end

  defp write_field(pf, value, index, project_id, item_id, opts) do
    field_name = Map.fetch!(@field_names, pf)

    case Map.get(index, String.downcase(field_name)) do
      nil ->
        Logger.debug("github projects: board has no #{field_name} field — skipping")
        :skip

      %{id: field_id, options: nil} ->
        # Text field (Goal) — write the value verbatim.
        update_text(project_id, item_id, field_id, to_string(value), opts)

      %{id: field_id, options: options} when is_map(options) ->
        write_single_select(pf, field_name, field_id, value, options, project_id, item_id, opts)
    end
  end

  defp write_single_select(pf, field_name, field_id, value, options, project_id, item_id, opts) do
    case Map.get(options, String.downcase(to_string(value))) do
      option_id when is_binary(option_id) ->
        update_single_select(project_id, item_id, field_id, option_id, opts)

      _ ->
        Logger.info(
          "github projects: #{field_name} has no option matching #{inspect(value)} " <>
            "(#{pf}) — skipping that field"
        )

        :skip
    end
  end

  defp update_single_select(project_id, item_id, field_id, option_id, opts) do
    vars = %{
      "projectId" => project_id,
      "itemId" => item_id,
      "fieldId" => field_id,
      "optionId" => option_id
    }

    case client(opts).graphql(@update_single_select_mutation, vars, opts) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp update_text(project_id, item_id, field_id, text, opts) do
    vars = %{
      "projectId" => project_id,
      "itemId" => item_id,
      "fieldId" => field_id,
      "text" => text
    }

    case client(opts).graphql(@update_text_mutation, vars, opts) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Desired-value derivation (mirrors Projection's label sources)
  # ---------------------------------------------------------------------------

  # status mirrors the projection's status-label source: the raw
  # lifecycle_status string (nil when absent/blank).
  defp value_for(:status, content), do: present_string(get(content, "lifecycle_status"))
  defp value_for(:priority, content), do: get(content, "priority")
  defp value_for(:worker, content), do: worker(content)
  defp value_for(:goal, content), do: present_string(get(content, "parent_id"))
  defp value_for(_other, _content), do: nil

  # The claimed worker lives at content.claim.worker; a flat content.worker is a
  # tolerated fallback (mirrors Projection.worker/1). Never the epoch/fence.
  defp worker(content) do
    w =
      case get(content, "claim") do
        claim when is_map(claim) -> get(claim, "worker") || get(content, "worker")
        _ -> get(content, "worker")
      end

    present_string(w)
  end

  defp present_string(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present_string(_), do: nil

  # ---------------------------------------------------------------------------
  # GraphQL response shape helpers
  # ---------------------------------------------------------------------------

  defp node_id(issue) when is_map(issue), do: issue["node_id"] || issue[:node_id]
  defp node_id(_), do: nil

  defp added_item_id(data) when is_map(data) do
    get_in(unwrap(data), ["addProjectV2ItemById", "item", "id"])
  end

  defp added_item_id(_), do: nil

  # slice-1 `graphql/2` returns `{:ok, data_or_body}` — tolerate BOTH the
  # unwrapped `data` object and a raw body still carrying a top-level `"data"`.
  defp unwrap(%{"data" => d}) when is_map(d), do: d
  defp unwrap(other), do: other

  # Build a case-insensitive index: field-name → %{id, options}. `options` is a
  # name→id map for a single-select, or nil for any other (text/common) field.
  defp index_fields(data) when is_map(data) do
    (get_in(unwrap(data), ["node", "fields", "nodes"]) || [])
    |> Enum.reduce(%{}, fn node, acc ->
      case node do
        %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
          Map.put(acc, String.downcase(name), %{id: id, options: option_index(node["options"])})

        _ ->
          acc
      end
    end)
  end

  defp index_fields(_), do: %{}

  defp option_index(options) when is_list(options) do
    Enum.reduce(options, %{}, fn
      %{"id" => id, "name" => name}, acc when is_binary(id) and is_binary(name) ->
        Map.put(acc, String.downcase(name), id)

      _, acc ->
        acc
    end)
  end

  defp option_index(_), do: nil

  # ---------------------------------------------------------------------------
  # Config / seams / key-tolerant accessors
  # ---------------------------------------------------------------------------

  # The Projects gate (D10): opts override for tests, else the resolved cred.
  defp project_id(opts) do
    # The GitHub Projects v2 board id is PLUGIN config (Settings), never a
    # per-reconcile opt. Read a distinct `:github_project_id` test-injection seam
    # — NOT `:project_id`, which MirrorJob overloads with the TENANCY project scope
    # (a workspace-project UUID). Reading `:project_id` here made every scoped task
    # mistake its tenancy UUID for the board id and fire a doomed GraphQL call.
    raw = Keyword.get(opts, :github_project_id) || Settings.get_credentials()[:project_id]

    case raw do
      v when is_binary(v) -> if String.trim(v) == "", do: nil, else: v
      _ -> nil
    end
  end

  defp client(opts) do
    Keyword.get(opts, :client) ||
      Application.get_env(:barkpark, :github_client) ||
      @default_client
  end

  defp link_map(link, task_doc) do
    cond do
      is_map(link) -> link
      true -> Link.get(task_doc) || %{}
    end
  end

  defp content_of(%{content: c}) when is_map(c), do: c
  defp content_of(%{"content" => c}) when is_map(c), do: c
  defp content_of(_), do: %{}

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp get(_, _), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
