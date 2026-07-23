defmodule Barkpark.StudioChat.Runtime.Codex.Protocol do
  @moduledoc false

  alias Barkpark.StudioChat.Runtime.Event

  @approval_methods [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval"
  ]

  def approval_method?(method), do: method in @approval_methods

  def approval_response(method, decision) when method in @approval_methods do
    case normalize_decision(decision) do
      decision
      when method == "item/permissions/requestApproval" and decision in ["decline", "cancel"] ->
        {:error, %{"code" => -32_001, "message" => decision}}

      decision when method == "item/permissions/requestApproval" ->
        {:ok, %{"permissions" => decision}}

      decision ->
        {:ok, %{"decision" => decision}}
    end
  end

  def normalize(message, context) do
    method = message["method"]
    params = message["params"] || %{}
    native = scrub(message)

    base = %Event{
      provider: "codex",
      session_id: context.session_id,
      provider_session_id: params["threadId"] || context.thread_id,
      turn_id: params["turnId"] || get_in(params, ["turn", "id"]) || context.turn_id,
      item_id: params["itemId"] || get_in(params, ["item", "id"]),
      sequence: context.sequence,
      idempotency_key: idempotency_key(message, context.sequence),
      native: native
    }

    case method do
      "thread/started" ->
        durable(base, :session_started,
          provider_session_id: get_in(params, ["thread", "id"]) || context.thread_id
        )

      "turn/started" ->
        durable(base, :turn_started)

      "item/agentMessage/delta" ->
        delta(base, :text_delta)

      "item/reasoning/textDelta" ->
        delta(base, :thinking_delta)

      "item/reasoning/summaryTextDelta" ->
        delta(base, :thinking_delta)

      "item/commandExecution/outputDelta" ->
        delta(base, :tool_delta)

      "item/fileChange/outputDelta" ->
        delta(base, :tool_delta)

      "item/started" ->
        durable(base, :item_started)

      "item/completed" ->
        durable(base, :item_completed)

      "thread/tokenUsage/updated" ->
        durable(base, :usage, usage: normalize_usage(params["tokenUsage"]))

      "turn/completed" ->
        status = get_in(params, ["turn", "status"])
        durable(base, :turn_completed, terminal_state: terminal_state(status))

      "error" ->
        durable(base, :error,
          terminal_state: :failed,
          error: sanitize_error(params["error"] || params)
        )

      method when method in @approval_methods ->
        approval_id = to_string(message["id"])
        durable(base, :approval_requested, approval_id: approval_id)

      _ ->
        durable(base, :provider_event)
    end
  end

  @doc "Normalize the authoritative thread start/resume acknowledgement."
  def acknowledgement(result, context) when is_map(result) do
    native = scrub(result)

    %Event{
      provider: "codex",
      session_id: context.session_id,
      provider_session_id: get_in(result, ["thread", "id"]) || context.thread_id,
      sequence: context.sequence,
      idempotency_key: "codex:runtime_acknowledged:" <> fingerprint(native),
      durability: :durable,
      kind: :runtime_acknowledged,
      observed_model: clean_text(result["model"]),
      observed_effort: clean_text(result["reasoningEffort"]),
      native: native
    }
  end

  def process_failed(context, status, stderr \\ nil) do
    %Event{
      provider: "codex",
      session_id: context.session_id,
      provider_session_id: context.thread_id,
      turn_id: context.turn_id,
      sequence: context.sequence,
      idempotency_key: "codex:process:#{context.sequence}",
      durability: :durable,
      kind: :process_failed,
      terminal_state: :failed,
      error: %{"code" => "process_exit", "status" => status, "detail" => scrub_text(stderr)},
      native: %{}
    }
  end

  def buffer_overflow(context, byte_size) do
    %Event{
      provider: "codex",
      session_id: context.session_id,
      provider_session_id: context.thread_id,
      turn_id: context.turn_id,
      sequence: context.sequence,
      idempotency_key: "codex:buffer_overflow:#{context.sequence}",
      durability: :durable,
      kind: :protocol_error,
      error: %{
        "code" => "buffer_overflow",
        "detail" => "reassembly buffer exceeded #{byte_size} bytes"
      },
      native: %{}
    }
  end

  def malformed(context, line) do
    %Event{
      provider: "codex",
      session_id: context.session_id,
      provider_session_id: context.thread_id,
      turn_id: context.turn_id,
      sequence: context.sequence,
      idempotency_key: "codex:malformed:#{context.sequence}",
      durability: :durable,
      kind: :protocol_error,
      error: %{"code" => "malformed_jsonl", "detail" => scrub_text(line)},
      native: %{}
    }
  end

  defp durable(event, kind, overrides \\ []) do
    struct!(event, Keyword.merge([durability: :durable, kind: kind], overrides))
  end

  defp delta(event, kind), do: struct!(event, durability: :delta, kind: kind)

  defp terminal_state("completed"), do: :completed
  defp terminal_state("interrupted"), do: :interrupted
  defp terminal_state("failed"), do: :failed
  defp terminal_state(status) when is_binary(status), do: status
  defp terminal_state(_), do: :completed

  defp normalize_decision(decision) when decision in [:allow, :accept, "allow", "accept"],
    do: "accept"

  defp normalize_decision(decision)
       when decision in [:allow_session, :accept_for_session, "allow_session", "acceptForSession"],
       do: "acceptForSession"

  defp normalize_decision(decision) when decision in [:cancel, "cancel"], do: "cancel"
  defp normalize_decision(_), do: "decline"

  defp idempotency_key(message, _sequence) do
    method = message["method"] || "response"
    id = message["id"] || get_in(message, ["params", "itemId"]) || "event"
    "codex:#{method}:#{id}:#{fingerprint(message)}"
  end

  defp normalize_usage(token_usage) when is_map(token_usage) do
    total = token_usage["total"] || token_usage[:total] || token_usage
    last = token_usage["last"] || token_usage[:last] || token_usage

    %{
      total: normalize_breakdown(total),
      last: normalize_breakdown(last),
      model_context_window:
        non_negative_integer(
          token_usage["modelContextWindow"] || token_usage[:model_context_window]
        )
    }
  end

  defp normalize_usage(_),
    do: %{total: empty_breakdown(), last: empty_breakdown(), model_context_window: nil}

  defp normalize_breakdown(value) when is_map(value) do
    %{
      total_tokens: metric(value, "totalTokens", :total_tokens),
      input_tokens: metric(value, "inputTokens", :input_tokens),
      cached_input_tokens: metric(value, "cachedInputTokens", :cached_input_tokens),
      output_tokens: metric(value, "outputTokens", :output_tokens),
      reasoning_output_tokens: metric(value, "reasoningOutputTokens", :reasoning_output_tokens)
    }
  end

  defp normalize_breakdown(_), do: empty_breakdown()

  defp empty_breakdown do
    %{
      total_tokens: nil,
      input_tokens: nil,
      cached_input_tokens: nil,
      output_tokens: nil,
      reasoning_output_tokens: nil
    }
  end

  defp metric(map, string_key, atom_key),
    do: non_negative_integer(Map.get(map, string_key, Map.get(map, atom_key)))

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_), do: nil

  defp fingerprint(value) do
    value
    |> scrub()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sanitize_error(error) when is_map(error) do
    %{
      "code" => error["code"],
      "message" => scrub_text(error["message"]),
      "details" => scrub(error["details"] || error["data"])
    }
  end

  defp sanitize_error(error), do: %{"message" => scrub_text(error)}

  defp scrub(value) when is_map(value) do
    value
    |> Map.drop(["token", "accessToken", "refreshToken", "apiKey", "authorization"])
    |> Map.new(fn {key, nested} -> {key, scrub(nested)} end)
  end

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value) when is_binary(value), do: scrub_text(value)
  defp scrub(value), do: value

  defp scrub_text(nil), do: nil
  defp scrub_text(value) when not is_binary(value), do: inspect(value, limit: 20)
  defp scrub_text(value), do: String.slice(value, 0, 2_000)

  defp clean_text(value) when is_binary(value) and value != "", do: value
  defp clean_text(_), do: nil
end
