defmodule Barkpark.Tasks.Judge do
  @moduledoc """
  Tier-2 dedup judge (task-obsession layer 2) — the semantic call tier-1's
  lexical similarity can't make. Consulted ONLY on tier-1's `advise` band (the
  gray zone between the advise and refuse thresholds); a confident `duplicate` /
  `already_landed` verdict there escalates a would-be-allowed create to a refuse.

  Everything about it is opt-in and fails open:

    * **Env-gated.** Runs only when an Anthropic key is configured
      (`config :barkpark, :anthropic_api_key`, or `ANTHROPIC_API_KEY`). With no
      key, `configured?/0` is false and the caller stays on the tier-1 verdict —
      the deployed server wires the key via run-secrets; local/CI needs none.
    * **Fails open.** Any error (HTTP failure, timeout, unparseable body) returns
      `{:error, _}` and the caller keeps the tier-1 verdict. A judge outage must
      never block a create.
    * **Mockable.** The HTTP call goes through a swappable adapter
      (`config :barkpark, :judge_http_adapter`), mirroring the webhook
      dispatcher's `ReqAdapter` seam — tests inject a fake, no network.

  The rubric mirrors `tooling/task-obsession/judge_prompt.md` (the canonical,
  calibration-frozen prompt); keep the two in sync. Structured outputs
  (`output_config.format`) guarantee the `{relation, confidence, reason}` shape.
  """
  require Logger

  @endpoint "https://api.anthropic.com/v1/messages"
  @model "claude-opus-4-8"
  @anthropic_version "2023-06-01"
  @max_tokens 1024

  # Frozen rubric — mirror of tooling/task-obsession/judge_prompt.md. The full
  # nuance lives in the task-obsession paper; this is what the model needs.
  @system """
  You decide the relationship between two Barkpark tasks (A and B) so an author \
  is warned before filing a duplicate. A cheap lexical filter already found them \
  similar; your job is the semantic call it cannot make: same change twice, or \
  just similar-sounding but distinct work?

  Pick exactly one relation:
  - duplicate — A and B would land essentially the SAME change; closing one makes \
    the other redundant. The only relation that should block a create. Require \
    the WORK PRODUCT to overlap, not just the vocabulary.
  - expands — one task's scope strictly contains the other (a milestone and one of \
    its steps). Not a duplicate; say which is broader.
  - already_landed — one side is `done` and already delivers the change the other \
    describes.
  - distinct — different work products. The DEFAULT and most common verdict.

  These are NEVER duplicate (the calibration exclusions): same-parent siblings \
  (an epic decomposed into slices), milestone⊇step parent-chain pairs (mind the \
  `drafts.` id prefix), and shared-boilerplate batches (judge the specific title \
  subject, not templated description text).

  Emit high confidence for clear `distinct` verdicts too — most pairs are \
  confidently distinct.
  """

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "relation" => %{
        "type" => "string",
        "enum" => ["duplicate", "expands", "already_landed", "distinct"]
      },
      "confidence" => %{"type" => "number"},
      "reason" => %{"type" => "string"}
    },
    "required" => ["relation", "confidence", "reason"]
  }

  @type verdict :: %{relation: String.t(), confidence: float(), reason: String.t()}

  @doc "True when an Anthropic key is configured — otherwise tier-2 is skipped."
  @spec configured?() :: boolean()
  def configured?, do: key() != nil

  @doc """
  Judge whether task `a` (the new task) duplicates candidate `b`. Returns
  `{:ok, verdict}` or `{:error, reason}` (caller falls back to tier-1 on error).
  Each task is a map with `:title`, `:description`, `:parent`, `:lifecycle`.
  """
  @spec judge(map(), map()) :: {:ok, verdict()} | {:error, term()}
  def judge(a, b) do
    case key() do
      nil -> {:error, :not_configured}
      _ -> do_judge(a, b)
    end
  end

  defp do_judge(a, b) do
    body = %{
      "model" => model(),
      "max_tokens" => @max_tokens,
      # Rubric before the cache breakpoint; the volatile pair after it, so bursts
      # of creates read the cached prefix.
      "system" => [
        %{"type" => "text", "text" => @system, "cache_control" => %{"type" => "ephemeral"}}
      ],
      "messages" => [%{"role" => "user", "content" => render_pair(a, b)}],
      "output_config" => %{
        "effort" => "low",
        "format" => %{"type" => "json_schema", "schema" => @schema}
      }
    }

    case adapter().post(@endpoint, body, headers()) do
      {:ok, 200, resp} -> parse_verdict(resp)
      {:ok, status, _resp} -> {:error, {:http_status, status}}
      {:error, _} = err -> err
      other -> {:error, {:unexpected, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp render_pair(a, b) do
    "A [#{a[:lifecycle]}] parent=#{a[:parent]}: #{a[:title]}\n   #{a[:description]}\n" <>
      "B [#{b[:lifecycle]}] parent=#{b[:parent]}: #{b[:title]}\n   #{b[:description]}"
  end

  # Structured outputs: the model's reply is a single text block whose text is
  # the JSON matching @schema.
  defp parse_verdict(resp) when is_map(resp) do
    with text when is_binary(text) <- first_text(resp),
         {:ok, %{"relation" => rel, "confidence" => conf} = m} <- Jason.decode(text) do
      {:ok, %{relation: rel, confidence: conf * 1.0, reason: Map.get(m, "reason", "")}}
    else
      _ -> {:error, :unparseable}
    end
  end

  defp parse_verdict(_), do: {:error, :unparseable}

  defp first_text(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => t} -> t
      _ -> nil
    end)
  end

  defp first_text(_), do: nil

  defp headers do
    [
      {"x-api-key", key()},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  defp adapter, do: Application.get_env(:barkpark, :judge_http_adapter, __MODULE__.ReqAdapter)

  defp model, do: Application.get_env(:barkpark, :judge_model, @model)

  defp key do
    Application.get_env(:barkpark, :anthropic_api_key) ||
      case System.get_env("ANTHROPIC_API_KEY") do
        "" -> nil
        v -> v
      end
  end

  defmodule ReqAdapter do
    @moduledoc "Real HTTP adapter for the judge — a thin Req.post. Swapped in tests."
    @spec post(String.t(), map(), [{String.t(), String.t()}]) ::
            {:ok, integer(), map()} | {:error, term()}
    def post(url, body, headers) do
      case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
        {:ok, %Req.Response{status: status, body: resp_body}} -> {:ok, status, resp_body}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
