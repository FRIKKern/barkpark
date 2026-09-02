defmodule Barkpark.StudioChat.Titles do
  @moduledoc """
  AI-generated thread titles for the Studio Claude chat — a layered, one-shot,
  fire-and-forget summarizer that turns the first user message of a session into
  a short, human-legible title.

  Three strategy layers, tried in order, each falling to the next on any failure
  (charter D13). Everything fails **soft** — the worst case is a serviceable
  derived title, never a crash or a blocked chat:

    1. **Anthropic Messages API** — used when a key is configured
       (`config :barkpark, :anthropic_api_key` or `ANTHROPIC_API_KEY`). A cheap
       Haiku call with structured output (`output_config.format` json_schema
       `{title}`) and `effort: "low"`, mirroring `Barkpark.Tasks.Judge`.
    2. **Claude CLI one-shot** — when no key (or the API call failed) but the
       host has the `claude` binary. `--no-session-persistence` keeps the
       throwaway call out of `~/.claude/projects` (D1 hygiene); the call is
       time-boxed with `Task.yield/2` + `Task.shutdown(_, :brutal_kill)` because
       `System.cmd` has no timeout, and the dev host's cmux-wrapped `claude` can
       return empty stdout under concurrency — so fallback-on-empty is not
       optional.
    3. **Derived** — the first line of the message, trimmed to 50 chars. Always
       succeeds.

  ## Seams (all injectable, so tests never touch the network or a real `claude`)

    * `:studio_chat_title_http_adapter` — the Anthropic HTTP call (default
      `ReqAdapter`), mirroring the judge's adapter seam.
    * `:studio_chat_title_cli` — the CLI runner (default `CliRunner`).
    * `:studio_chat_store` — the persistence layer whose `maybe_set_ai_title/2`
      holds the clobber guard (default `Barkpark.StudioChat`, delivered by the
      store slice).
    * `:studio_chat_title_model`, `:studio_chat_title_binary`,
      `:studio_chat_title_timeout_ms` — tunables.
    * `:anthropic_api_url` (`ANTHROPIC_API_URL`) — the Messages endpoint, shared
      with `Barkpark.Tasks.Judge` the way `:anthropic_api_key` already is, so an
      operator behind an Anthropic-compatible gateway can move the URL as well
      as the key and the model. See `endpoint/0`.

  D9: the pure builders (`api_request/1`, `cli_args/1`, `parse_title/1`,
  `derived_title/1`) are unit-tested directly, so an adapter or CLI override can
  never bypass untested argument assembly.
  """
  require Logger

  # The DEFAULT endpoint, not the value — see `endpoint/0`. It used to be read
  # directly at the call site, which a release BUILD freezes: the adapter, the
  # model and the key were all config-read here and only the URL was not, so an
  # operator behind an Anthropic-compatible gateway could supply the key and the
  # model and still not move the URL (gh-9531 residual,
  # task-eeabfd9bf3ed8371).
  @default_endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @model "claude-haiku-4-5"
  @cli_model "haiku"
  @default_binary "claude"
  @max_tokens 64
  @title_cap 50
  @cli_timeout_ms 15_000
  @default_title "New chat"

  @system """
  You generate concise thread titles for coding conversations. Output only the \
  requested JSON, nothing else.
  """

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{"title" => %{"type" => "string"}},
    "required" => ["title"]
  }

  # ── Pure builders (unit-tested directly) ─────────────────────────────────

  @doc """
  The Anthropic Messages request body for `first_message`: a Haiku model, a
  tiny `max_tokens`, and structured output pinning the reply to `{title}` at
  `effort: "low"` (the `Barkpark.Tasks.Judge` shape).
  """
  @spec api_request(String.t()) :: map()
  def api_request(first_message) when is_binary(first_message) do
    %{
      "model" => model(),
      "max_tokens" => @max_tokens,
      "system" => @system,
      "messages" => [%{"role" => "user", "content" => user_prompt(first_message)}],
      "output_config" => %{
        "effort" => "low",
        "format" => %{"type" => "json_schema", "schema" => @schema}
      }
    }
  end

  @doc """
  The Claude CLI argv for a one-shot title generation. `--no-session-persistence`
  is mandatory (keeps the throwaway call out of `~/.claude/projects`);
  `--max-turns 1` and `--strict-mcp-config` keep it cheap and hermetic. Never
  emits a bare `--tools` (it would swallow the following flag).
  """
  @spec cli_args(String.t()) :: [String.t()]
  def cli_args(first_message) when is_binary(first_message) do
    [
      "-p",
      user_prompt(first_message),
      "--model",
      @cli_model,
      "--output-format",
      "json",
      "--max-turns",
      "1",
      "--no-session-persistence",
      "--strict-mcp-config",
      "--system-prompt",
      String.trim(@system)
    ]
  end

  @doc """
  Extract a title from a raw model/CLI response. Tolerant to the three shapes
  seen in the wild: a fenced ```` ```json ```` block (how the CLI wraps its
  reply — verified on the real binary, and it may carry a rambling preamble),
  bare `{title}` JSON, and the CLI's `--output-format json` envelope
  (`{result: "..."}`, whose `result` holds one of the former). Returns
  `{:ok, title}` (trimmed, capped at #{@title_cap} chars) or `{:error, reason}`.
  """
  @spec parse_title(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def parse_title(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    # Decode the outer JSON first: a bare `{title}` finishes here, and the CLI's
    # `{result}` envelope recurses on its (fenced) inner payload. Only when the
    # input is NOT valid JSON on its own do we reach for an embedded code fence.
    case Jason.decode(trimmed) do
      {:ok, %{"title" => title}} when is_binary(title) -> finalize(title)
      {:ok, %{"result" => result}} when is_binary(result) -> parse_title(result)
      _ -> parse_fenced(trimmed)
    end
  end

  def parse_title(_), do: {:error, :unparseable}

  @doc "The always-succeeds fallback: the first line of the message, capped."
  @spec derived_title(term()) :: String.t()
  def derived_title(first_message) when is_binary(first_message) do
    first_message
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> cap()
    |> case do
      "" -> @default_title
      title -> title
    end
  end

  def derived_title(_), do: @default_title

  # ── Strategy ─────────────────────────────────────────────────────────────

  @doc """
  Produce a title for `first_message`, trying the API then the CLI then the
  derived fallback. Never raises; always returns a non-empty binary.
  """
  @spec generate(String.t()) :: String.t()
  def generate(first_message) when is_binary(first_message) do
    with :error <- try_api(first_message),
         :error <- try_cli(first_message) do
      derived_title(first_message)
    else
      title when is_binary(title) -> title
    end
  end

  def generate(_), do: @default_title

  @doc """
  Fire-and-forget: generate a title for `session_id` off the request path (a
  supervised task under `Barkpark.TaskSupervisor`), hand it to the store's
  clobber guard (`maybe_set_ai_title/2` — a human rename is never overwritten),
  and, only if the store accepted the write, hand it to
  `Recorder.broadcast_title/2` (ct-bl-recorder-titles), which publishes
  `{:chat_title, session_id, title}` on the activity topic (Studio's sidebar +
  the `FleetHub`, which re-projects it onto `GET /v1/chat/events`) AND on
  `Recorder.topic/1` (the per-session SSE forwarder — `bp chat` and any other
  headless client). There is no per-pid delivery fork anywhere: every surface
  learns the title from the Recorder's topics, never from a `send/2` to the
  caller. A refusal or any error is silent — the default title simply stands
  (`broadcast/3` cannot raise, so the fire-and-forget guard holds).
  Returns the started task's `{:ok, pid}` (or `{:error, reason}` if the
  supervisor rejects it).
  """
  @spec kick_title(term(), String.t()) :: DynamicSupervisor.on_start_child()
  def kick_title(session_id, first_message) when is_binary(first_message) do
    Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
      title = generate(first_message)

      try do
        # Accepted-write shapes: the canonical store returns {:ok, %Session{}}
        # (notify with its applied title); tolerate {:ok, title} / plain :ok
        # from simpler stores. Anything else is a refusal — stay silent.
        case store().maybe_set_ai_title(session_id, title) do
          {:ok, %{title: applied}} when is_binary(applied) ->
            broadcast_title(session_id, applied)

          {:ok, applied} when is_binary(applied) ->
            broadcast_title(session_id, applied)

          :ok ->
            broadcast_title(session_id, title)

          _refused ->
            :ok
        end
      rescue
        e ->
          Logger.debug("studio chat title: store write failed: #{inspect(e)}")
          :ok
      catch
        # A store that isn't loaded/started exits (GenServer.call to a dead
        # name) rather than raising — swallow that too, never leak.
        kind, reason ->
          Logger.debug("studio chat title: store write #{kind}: #{inspect(reason)}")
          :ok
      end
    end)
  end

  @doc """
  Call-site-stability head: delivery rides the Recorder's topics now, so the
  `notify_pid` is ignored — a caller that subscribes either topic (the chat
  LiveView does, at mount) receives the same `{:chat_title, ...}` tuple it
  always handled.
  """
  @spec kick_title(term(), String.t(), pid()) :: DynamicSupervisor.on_start_child()
  def kick_title(session_id, first_message, notify_pid)
      when is_binary(first_message) and is_pid(notify_pid),
      do: kick_title(session_id, first_message)

  # ── Internals ────────────────────────────────────────────────────────────

  # The accepted-write notify step. Publishing is the RECORDER's job now
  # (ct-bl-recorder-titles): `Recorder.broadcast_title/2` owns which topics the
  # event rides — the activity topic for Studio/FleetHub (D69h) AND the
  # per-session topic the SSE forwarder holds (D22 shape), so headless clients
  # stop polling. This module keeps only the decision of WHEN to publish: after
  # the store's clobber guard accepted the write, never before. It cannot raise
  # (PubSub with no subscribers is `:ok`), so the fire-and-forget guard holds.
  defp broadcast_title(session_id, title) do
    Barkpark.StudioChat.Recorder.broadcast_title(session_id, title)
  end

  # Returns a binary title on success, or :error to fall to the next layer.
  defp try_api(first_message) do
    case key() do
      nil ->
        :error

      _key ->
        case adapter().post(endpoint(), api_request(first_message), headers()) do
          {:ok, 200, resp} ->
            case parse_title(api_text(resp)) do
              {:ok, title} -> title
              _ -> :error
            end

          _ ->
            :error
        end
    end
  rescue
    _ -> :error
  end

  # Time-boxed CLI one-shot; :error on unavailable binary, timeout, crash,
  # empty stdout, or unparseable output.
  defp try_cli(first_message) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        cli_runner().run(binary(), cli_args(first_message))
      end)

    case Task.yield(task, cli_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, stdout}} ->
        case parse_title(stdout) do
          {:ok, title} -> title
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # Structured output arrives as a single text block whose text is the JSON.
  defp api_text(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, "", fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      _ -> false
    end)
  end

  defp api_text(_), do: ""

  # Decode the contents of the first fenced code block (tolerating a rambling
  # preamble/suffix around it). Used only after the input failed to decode as
  # bare/enveloped JSON.
  defp parse_fenced(trimmed) do
    case Regex.run(~r/```(?:json)?\s*(.*?)```/s, trimmed, capture: :all_but_first) do
      [inner] ->
        case Jason.decode(String.trim(inner)) do
          {:ok, %{"title" => title}} when is_binary(title) -> finalize(title)
          _ -> {:error, :unparseable}
        end

      _ ->
        {:error, :unparseable}
    end
  end

  defp finalize(title) do
    case title |> String.trim() |> cap() do
      "" -> {:error, :empty}
      capped -> {:ok, capped}
    end
  end

  defp cap(title) do
    title |> String.slice(0, @title_cap) |> String.trim_trailing()
  end

  defp user_prompt(first_message) do
    """
    Summarize the INTENT of this first message from a coding conversation into a \
    thread title of 3-8 words, at most #{@title_cap} characters. No quotes, no \
    filler, no "Chat about"/"Help with" prefixes — just the subject.

    Reply with ONLY this JSON, nothing else: {"title":"..."}

    First message:
    #{first_message}
    """
  end

  defp headers do
    [
      {"x-api-key", key()},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  @doc """
  The Anthropic-compatible Messages endpoint the title call posts to.

  Read at CALL time from `config :barkpark, :anthropic_api_url`
  (`ANTHROPIC_API_URL` in `config/runtime.exs`), defaulting to Anthropic's own
  URL — an unconfigured deployment is byte-identical to before. Shares one key
  with `Barkpark.Tasks.Judge`, exactly as `:anthropic_api_key` is already
  shared: one gateway serves both callers.

  FAILS CLOSED: a configured-but-malformed URL raises rather than falling back
  to api.anthropic.com. A silent fallback would send an operator's chat content
  — and their key — to the vendor they deliberately routed away from.
  `Barkpark.Application.start/2` resolves it once at boot, so a typo refuses the
  node instead of surfacing as titles that quietly drop to the CLI/derived
  layers (every failure on this path is swallowed by design).
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

  defp adapter,
    do: Application.get_env(:barkpark, :studio_chat_title_http_adapter, __MODULE__.ReqAdapter)

  defp cli_runner,
    do: Application.get_env(:barkpark, :studio_chat_title_cli, __MODULE__.CliRunner)

  defp store, do: Application.get_env(:barkpark, :studio_chat_store, Barkpark.StudioChat)

  defp model, do: Application.get_env(:barkpark, :studio_chat_title_model, @model)

  defp binary, do: Application.get_env(:barkpark, :studio_chat_title_binary, @default_binary)

  defp cli_timeout,
    do: Application.get_env(:barkpark, :studio_chat_title_timeout_ms, @cli_timeout_ms)

  defp key do
    Application.get_env(:barkpark, :anthropic_api_key) ||
      case System.get_env("ANTHROPIC_API_KEY") do
        "" -> nil
        nil -> nil
        v -> v
      end
  end

  defmodule ReqAdapter do
    @moduledoc "Real HTTP adapter for the title call — a thin `Req.post`. Swapped in tests."
    @spec post(String.t(), map(), [{String.t(), String.t()}]) ::
            {:ok, integer(), map()} | {:error, term()}
    def post(url, body, headers) do
      case Req.post(url, json: body, headers: headers, receive_timeout: 15_000) do
        {:ok, %Req.Response{status: status, body: resp_body}} -> {:ok, status, resp_body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule CliRunner do
    @moduledoc """
    Real CLI runner — locates the binary and runs it with `System.cmd`. The
    timeout lives in the caller (`Task.yield` + `brutal_kill`), since
    `System.cmd` blocks with no timeout. Swapped in tests.
    """
    @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
    # Reachability: `binary` is the operator-config name resolved through
    # `System.find_executable/1`, and `args` is `cli_args/1`'s fixed argv list —
    # `System.cmd/3` spawns without a shell, so no argument can inject a command.
    # sobelow_skip ["CI.System"]
    def run(binary, args) do
      case System.find_executable(binary) do
        nil ->
          {:error, :binary_not_found}

        exe ->
          case System.cmd(exe, args, stderr_to_stdout: false) do
            {out, 0} -> {:ok, out}
            {_out, status} -> {:error, {:exit_status, status}}
          end
      end
    rescue
      e -> {:error, e}
    end
  end
end
