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
    * **Relocatable.** The endpoint is config-read too
      (`config :barkpark, :anthropic_api_url`, `ANTHROPIC_API_URL`), so an
      operator behind an Anthropic-compatible gateway can move the URL as well
      as the key and the model. See `endpoint/0`.

  The rubric mirrors `tooling/task-obsession/judge_prompt.md` (the canonical,
  calibration-frozen prompt); keep the two in sync. Structured outputs
  (`output_config.format`) guarantee the `{relation, confidence, reason}` shape.
  """
  require Logger

  # The DEFAULT endpoint, not the value — see `endpoint/0`. It used to be read
  # directly at the call site, which a release BUILD freezes: the adapter, the
  # model and the key were all config-read here and only the URL was not, so an
  # operator routing Anthropic-compatible traffic through a gateway (LiteLLM, an
  # internal proxy, a Bedrock-style shim) could supply the key and the model and
  # still not move the URL — the feature was simply unreachable for them
  # (gh-9531 residual, task-eeabfd9bf3ed8371).
  @default_endpoint "https://api.anthropic.com/v1/messages"
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

    case adapter().post(endpoint(), body, headers()) do
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

  @doc """
  The Anthropic-compatible Messages endpoint this judge posts to.

  Read at CALL time from `config :barkpark, :anthropic_api_url`
  (`ANTHROPIC_API_URL` in `config/runtime.exs`), defaulting to Anthropic's own
  URL — an unconfigured deployment is byte-identical to before. Shares one key
  with `Barkpark.StudioChat.Titles`, exactly as `:anthropic_api_key` is already
  shared: one gateway serves both callers.

  FAILS CLOSED: a configured-but-malformed URL raises rather than falling back
  to api.anthropic.com. A silent fallback would send an operator's prompts —
  and their key — to the vendor they deliberately routed away from.
  `Barkpark.Application.start/2` resolves it once at boot, so a typo refuses the
  node instead of surfacing as a judge that quietly never runs (every error on
  this path is swallowed by design: the judge fails OPEN so an outage cannot
  block a create).
  """
  @spec endpoint() :: String.t()
  def endpoint do
    case Application.get_env(:barkpark, :anthropic_api_url) do
      nil -> @default_endpoint
      configured -> validate_endpoint!(configured)
    end
  end

  @doc "The compile-time fallback endpoint — what \"unconfigured\" means, for tests."
  @spec default_endpoint() :: String.t()
  def default_endpoint, do: @default_endpoint

  # An http(s) URL with a host and no whitespace or control characters. The
  # value is handed to an HTTP client, so a CR/LF smuggled through config is
  # request splitting, not a typo.
  defp validate_endpoint!(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         not Regex.match?(~r/[\s[:cntrl:]]/, value) do
      value
    else
      bad_endpoint!(value)
    end
  end

  defp validate_endpoint!(other), do: bad_endpoint!(other)

  defp bad_endpoint!(value) do
    raise ArgumentError, """
    invalid Anthropic API URL: #{inspect(value)}.

    Expected an http(s) URL for an Anthropic-compatible Messages endpoint, e.g.
    "https://gateway.internal/v1/messages".

    Set ANTHROPIC_API_URL to your gateway, or leave it unset to keep the
    #{@default_endpoint} default.
    """
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
