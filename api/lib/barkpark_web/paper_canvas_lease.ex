defmodule BarkparkWeb.PaperCanvasLease do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BarkparkWeb.Studio.StudioLive.{Blocks, PaperCanvas}

  @salt "paper-canvas-retention-v1"
  @version 1
  @max_age 86_400
  @max_tokens 64
  @max_token_bytes 2_048
  @max_total_bytes 32_768
  @max_key_bytes 512

  @empty_attempt %{
    attempted?: false,
    malformed?: false,
    pending?: false,
    key: nil,
    tokens: []
  }
  @halt_notice "This editor could not safely resume after reconnecting. Your local editor is frozen. Reloading the server version discards unsaved local edits."

  @doc false
  def prepare_socket(socket) do
    params = Phoenix.LiveView.get_connect_params(socket) || %{}

    socket
    |> assign(:paper_canvas_resume_attempt, capture_params(params))
    |> assign(:paper_canvas_resume_halt, false)
    |> assign(:paper_canvas_resume_status, :none)
    |> assign(:paper_canvas_lease_tokens, %{})
    |> assign(:paper_canvas_lease_key, nil)
    |> assign(:paper_canvas_lease_scope, nil)
    |> Phoenix.LiveView.attach_hook(:paper_canvas_resume_halt, :handle_event, &halt_mutation/3)
  end

  @doc false
  def resume_socket(socket, paper, blocks, authorized?) do
    scope = scope(socket.assigns, paper)
    key = if valid_scope?(scope), do: paper_key(scope), else: nil

    case resume(
           socket.assigns[:paper_canvas_resume_attempt] || @empty_attempt,
           scope,
           blocks,
           authorized?
         ) do
      {:ok, ownership, tokens} ->
        socket
        |> assign(:paper_canvas_retained, ownership)
        |> assign(:paper_canvas_lease_tokens, tokens)
        |> assign(:paper_canvas_resume_halt, false)
        |> assign(:paper_canvas_resume_status, :resumed)
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)
        |> assign(:paper_canvas_resume_attempt, @empty_attempt)

      :halt ->
        socket
        |> assign(:paper_canvas_retained, nil)
        |> assign(:paper_canvas_lease_tokens, %{})
        |> assign(:paper_canvas_resume_halt, true)
        |> assign(:paper_canvas_resume_status, :blocked)
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)
        |> assign(:paper_canvas_resume_attempt, @empty_attempt)

      :pending ->
        socket
        |> assign(:paper_canvas_retained, nil)
        |> assign(:paper_canvas_lease_tokens, %{})
        |> assign(:paper_canvas_resume_halt, true)
        |> assign(:paper_canvas_resume_status, :pending)
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)
        |> assign(:paper_canvas_resume_attempt, @empty_attempt)

      {:pending, ownership, tokens} ->
        socket
        |> assign(:paper_canvas_retained, ownership)
        |> assign(:paper_canvas_lease_tokens, tokens)
        |> assign(:paper_canvas_resume_halt, true)
        |> assign(:paper_canvas_resume_status, :pending)
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)
        |> assign(:paper_canvas_resume_attempt, @empty_attempt)

      :none ->
        if authorized? != true do
          reset_socket(socket)
        else
          case socket.assigns[:paper_canvas_lease_scope] do
            nil ->
              socket
              |> assign(:paper_canvas_resume_attempt, @empty_attempt)
              |> assign(:paper_canvas_lease_key, key)
              |> assign(:paper_canvas_lease_scope, scope)

            ^scope ->
              assign(socket, :paper_canvas_resume_attempt, @empty_attempt)

            _different_scope ->
              socket
              |> reset_socket()
              |> assign(:paper_canvas_lease_key, key)
              |> assign(:paper_canvas_lease_scope, scope)
          end
        end
    end
  end

  @doc false
  def issue_socket(socket, paper, owners, blocks, revision) do
    scope = scope(socket.assigns, paper)
    key = if valid_scope?(scope), do: paper_key(scope), else: nil

    case issue(scope, owners, blocks, revision) do
      token_by_id when is_map(token_by_id) ->
        socket
        |> assign(:paper_canvas_lease_tokens, token_by_id)
        |> assign(:paper_canvas_resume_halt, false)
        |> assign(:paper_canvas_resume_status, :resumed)
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)

      :unsupported ->
        socket
        |> assign(:paper_canvas_lease_tokens, %{})
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)

      :overflow ->
        socket
        |> assign(:paper_canvas_lease_tokens, %{})
        |> assign(:paper_canvas_resume_halt, true)
        |> assign(:paper_canvas_resume_status, :blocked)
        |> assign(:paper_canvas_lease_key, key)
        |> assign(:paper_canvas_lease_scope, scope)
    end
  end

  @doc false
  def reset_socket(socket) do
    socket
    |> assign(:paper_canvas_retained, nil)
    |> assign(:paper_canvas_lease_tokens, %{})
    |> assign(:paper_canvas_resume_halt, false)
    |> assign(:paper_canvas_resume_status, :none)
    |> assign(:paper_canvas_resume_attempt, @empty_attempt)
    |> assign(:paper_canvas_lease_key, nil)
    |> assign(:paper_canvas_lease_scope, nil)
  end

  @doc false
  def tokens(socket) do
    case socket.assigns[:paper_canvas_lease_tokens] do
      tokens when is_map(tokens) -> tokens |> Map.values() |> Enum.sort()
      _ -> []
    end
  end

  @doc false
  def halted?(socket), do: socket.assigns[:paper_canvas_resume_halt] == true

  @doc false
  def pending?(socket), do: socket.assigns[:paper_canvas_resume_status] == :pending

  @doc false
  def blocked?(socket), do: socket.assigns[:paper_canvas_resume_status] == :blocked

  @doc false
  def halt_notice, do: @halt_notice

  @doc false
  def capture_params(params) when is_map(params) do
    raw_tokens = Map.get(params, "paper_canvas_leases")
    tokens = raw_tokens || []
    pending? = Map.get(params, "paper_canvas_lease_pending") == true
    overflow? = Map.get(params, "paper_canvas_lease_overflow") == true
    key = Map.get(params, "paper_canvas_lease_key")

    attempted? =
      pending? or overflow? or
        (Map.has_key?(params, "paper_canvas_leases") and raw_tokens not in [nil, []])

    cond do
      not attempted? ->
        @empty_attempt

      not (is_binary(key) and key != "" and byte_size(key) <= @max_key_bytes) ->
        %{@empty_attempt | attempted?: true, malformed?: true, pending?: pending?}

      overflow? ->
        %{@empty_attempt | attempted?: true, malformed?: true, pending?: pending?, key: key}

      not valid_tokens?(tokens) ->
        %{@empty_attempt | attempted?: true, malformed?: true, pending?: pending?, key: key}

      true ->
        %{
          attempted?: true,
          malformed?: false,
          pending?: pending?,
          key: key,
          tokens: Enum.uniq(tokens)
        }
    end
  end

  def capture_params(_params), do: @empty_attempt

  @doc false
  def paper_key(%{dataset: dataset, doc_type: type, slug: slug}),
    do: "#{dataset}:#{type}:#{slug}"

  @doc false
  def scope(assigns, paper) when is_map(assigns) and is_map(paper) do
    %{
      workspace_id: doc_field(paper, :workspace_id),
      project_id: doc_field(paper, :project_id),
      dataset: Map.get(assigns, :dataset),
      doc_type: doc_field(paper, :type),
      slug: doc_field(paper, :doc_id),
      authority: authority(assigns)
    }
  end

  @doc false
  def issue(scope, owners, blocks, revision)
      when is_map(scope) and is_map(owners) and is_list(blocks) do
    with true <- valid_scope?(scope) || :unsupported,
         {:ok, expected_count} <- owner_count(owners) do
      token_by_id =
        owners
        |> Enum.sort_by(fn {owner, _ids} -> inspect(owner) end)
        |> Enum.flat_map(fn
          {owner, %MapSet{} = ids} ->
            ids
            |> Enum.sort()
            |> Enum.flat_map(fn id ->
              case PaperCanvas.retained_boundary_type(blocks, owner, id) do
                {:ok, type} -> [{id, sign(scope, owner, id, type, revision)}]
                :error -> []
              end
            end)

          _ ->
            []
        end)
        |> Map.new()

      if map_size(token_by_id) == expected_count and valid_tokens?(Map.values(token_by_id)),
        do: token_by_id,
        else: :overflow
    else
      :unsupported -> :unsupported
      _ -> :overflow
    end
  end

  def issue(_scope, _owners, _blocks, _revision), do: :unsupported

  @doc false
  def resume(attempt, scope, blocks, authorized?, opts \\ []) do
    cond do
      not (is_map(attempt) and Map.get(attempt, :attempted?) == true) ->
        :none

      not (is_map(scope) and Map.get(attempt, :key) == paper_key(scope)) ->
        :none

      authorized? != true ->
        :none

      Map.get(attempt, :malformed?) == true ->
        :halt

      Map.get(attempt, :pending?) == true ->
        resume_pending(attempt, scope, blocks, opts)

      not (is_list(Map.get(attempt, :tokens)) and is_list(blocks)) ->
        :halt

      Map.get(attempt, :tokens) == [] ->
        :halt

      true ->
        max_age = Keyword.get(opts, :max_age, @max_age)

        attempt.tokens
        |> Enum.map(&verify_token(&1, scope, max_age))
        |> resume_verified(scope, blocks)
    end
  end

  @doc false
  def for_run(token_by_id, blocks) when is_map(token_by_id) and is_list(blocks) do
    token_by_id
    |> Enum.filter(fn {id, _token} -> is_map(Blocks.find_paper_block(blocks, id)) end)
    |> Enum.sort_by(fn {id, _token} -> id end)
    |> Enum.map(fn {_id, token} -> token end)
  end

  def for_run(_token_by_id, _blocks), do: []

  defp resume_verified(results, scope, blocks) do
    current =
      Enum.flat_map(results, fn
        {:current, claim, token} -> [{claim, token}]
        _ -> []
      end)

    cond do
      Enum.any?(results, &(&1 in [:invalid, :foreign])) ->
        :halt

      current == [] ->
        :halt

      true ->
        owners =
          Enum.reduce(current, %{}, fn {claim, _token}, acc ->
            Map.update(
              acc,
              decode_owner(claim["owner"]),
              MapSet.new([claim["boundary_id"]]),
              fn ids ->
                MapSet.put(ids, claim["boundary_id"])
              end
            )
          end)

        refreshed = PaperCanvas.prune_retained(owners, blocks)

        valid_claims? =
          Enum.all?(current, fn {claim, _token} ->
            owner = decode_owner(claim["owner"])
            id = claim["boundary_id"]

            MapSet.member?(Map.get(refreshed, owner, MapSet.new()), id) and
              PaperCanvas.retained_boundary_type(blocks, owner, id) ==
                {:ok, claim["boundary_type"]}
          end)

        if valid_claims? and retained_count(refreshed) == length(current) do
          tokens = Map.new(current, fn {claim, token} -> {claim["boundary_id"], token} end)
          {:ok, %{slug: scope.slug, owners: refreshed}, tokens}
        else
          :halt
        end
    end
  end

  defp resume_pending(%{tokens: []}, _scope, _blocks, _opts), do: :pending

  defp resume_pending(attempt, scope, blocks, opts) do
    max_age = Keyword.get(opts, :max_age, @max_age)

    case attempt.tokens
         |> Enum.map(&verify_token(&1, scope, max_age))
         |> resume_verified(scope, blocks) do
      {:ok, ownership, tokens} -> {:pending, ownership, tokens}
      :halt -> :halt
    end
  end

  defp verify_token(token, scope, max_age) do
    case Phoenix.Token.verify(BarkparkWeb.Endpoint, @salt, token, max_age: max_age) do
      {:ok, %{"v" => @version} = claim} ->
        if claim_scope(claim) == scope, do: {:current, claim, token}, else: :foreign

      _ ->
        :invalid
    end
  end

  defp sign(scope, owner, id, type, revision) do
    Phoenix.Token.sign(BarkparkWeb.Endpoint, @salt, %{
      "v" => @version,
      "workspace_id" => scope.workspace_id,
      "project_id" => scope.project_id,
      "dataset" => scope.dataset,
      "doc_type" => scope.doc_type,
      "slug" => scope.slug,
      "authority" => scope.authority,
      "owner" => encode_owner(owner),
      "boundary_id" => id,
      "boundary_type" => type,
      "revision" => revision
    })
  end

  defp claim_scope(claim) do
    %{
      workspace_id: claim["workspace_id"],
      project_id: claim["project_id"],
      dataset: claim["dataset"],
      doc_type: claim["doc_type"],
      slug: claim["slug"],
      authority: claim["authority"]
    }
  end

  defp encode_owner(:document), do: ["document"]
  defp encode_owner({:section, id}), do: ["section", id]
  defp encode_owner({:columns, id, index}), do: ["columns", id, index]

  defp decode_owner(["document"]), do: :document
  defp decode_owner(["section", id]) when is_binary(id), do: {:section, id}

  defp decode_owner(["columns", id, index]) when is_binary(id) and is_integer(index),
    do: {:columns, id, index}

  defp decode_owner(_owner), do: :invalid

  defp valid_tokens?(tokens) when is_list(tokens) and length(tokens) <= @max_tokens do
    Enum.all?(tokens, &(is_binary(&1) and byte_size(&1) <= @max_token_bytes)) and
      Enum.reduce(tokens, 0, &(byte_size(&1) + &2)) <= @max_total_bytes
  end

  defp valid_tokens?(_tokens), do: false

  defp valid_scope?(scope) do
    Enum.all?([scope.workspace_id, scope.dataset, scope.doc_type, scope.slug, scope.authority], fn
      value -> is_binary(value) and value != ""
    end) and (is_nil(scope.project_id) or is_binary(scope.project_id))
  end

  defp retained_count(owners),
    do: Enum.reduce(owners, 0, fn {_owner, ids}, count -> count + MapSet.size(ids) end)

  defp owner_count(owners) do
    Enum.reduce_while(owners, {:ok, 0}, fn
      {_owner, %MapSet{} = ids}, {:ok, count} -> {:cont, {:ok, count + MapSet.size(ids)}}
      _entry, _count -> {:halt, :error}
    end)
  end

  defp authority(%{current_user: %{id: id}}) when is_binary(id), do: "user:" <> id
  defp authority(%{api_token: %{id: id}}) when is_binary(id), do: "token:" <> id

  defp authority(%{paper_share_grant: %{id: id}}) when is_binary(id),
    do: "share:" <> id

  defp authority(_assigns), do: nil

  defp doc_field(doc, field), do: Map.get(doc, field)

  defp halt_mutation(
         "paper-ops",
         _params,
         %{assigns: %{paper_canvas_resume_status: :pending}} = socket
       ),
       do: {:cont, socket}

  defp halt_mutation("paper-" <> _event, _params, socket) do
    if halted?(socket) do
      {:halt, Phoenix.LiveView.put_flash(socket, :error, @halt_notice)}
    else
      {:cont, socket}
    end
  end

  defp halt_mutation(_event, _params, socket), do: {:cont, socket}
end
