defmodule Barkpark.StudioChat.Probe do
  @moduledoc """
  Provider-neutral readiness probe for the Studio chat onboarding lane
  (epic chat-task-hands, wave 1, charter D2/D3 · decision 3).

  ONE pure function — `probe/1` — answers "is THIS provider's CLI present, and
  is it logged in?" for each lane the chat can drive. The onboarding card
  (`task-cth-w1-onboarding-card`, slice 3) reads the returned struct and renders
  a NAMED next step for every not-ready state (never fails silent, charter D2).

      %Barkpark.StudioChat.Probe{
        provider: :claude | :bp | :codex,
        binary:   boolean(),        # is the CLI resolvable on PATH?
        path:     String.t() | nil, # absolute path when present
        version:  String.t() | nil, # e.g. "2.1.207" (claude only)
        authed?:  boolean() | nil,  # nil = auth is not a probe concern (bp)
        account:  map() | nil        # %{email, org, subscription, method} when authed
      }

  ## The three lanes (each probes DIFFERENTLY — charter Verified ground 2026-07-11)

    * **`:claude`** — the live Anthropic `claude` binary. Resolve via
      `System.find_executable/1`, then `claude --version` (works with ZERO
      credentials), then `claude auth status --json`. The auth shape is proven:
      exit 0 + `{loggedIn: true, authMethod, email, orgName, subscriptionType}`
      when authed; exit 1 + `{loggedIn: false, authMethod: "none"}` when not.
      **Expired credentials are indistinguishable from never-logged-in without
      an API call — both degrade to `authed?: false` BY DESIGN** (charter D2:
      the shapes collapse, so the card shows the same "log in" next step).

    * **`:bp`** — binary presence/path ONLY. bp's auth is mint-driven
      server-side: the chat spawn mints a scoped `bpcs_` token into the child's
      env (charter D1/D3). There is NO bp login step and NO config file to
      probe, so `authed?` is `nil` (not-applicable) — the bp not-ready states
      (`no_task_hands` / `task_token_expired`, charter D2) are surfaced at spawn
      time by the mint, not here.

    * **`:codex`** — resolves the pinned Codex CLI, verifies the app-server
      version contract, and performs its account-read readiness handshake.
      The honest capability flags live in
      `Barkpark.StudioChat.Runtime.Capabilities.codex/0`.

  ## LATENCY — callers MUST run this ASYNC (this is not optional)

  `claude auth status --json` costs **~1–2s** (measured 1.0–2.0s on the guerrilla
  host, charter Verified ground). Running `probe(:claude)` inline in a LiveView
  `mount/3` would BLOCK the socket connect for up to two seconds — a visibly
  janky first paint. The onboarding card MUST probe off the LiveView process
  (`Task.async` + `handle_info`, or the dispatch_send template) and render a
  spinner until the result lands. `probe(:bp)` and `probe(:codex)` are cheap
  (find_executable only), but treat the whole seam as async so no lane surprises
  you when the claude version/auth shell-outs are added to a fast path.

  ## Config-injectable binary names (test seam — existing fake-binary idiom)

  Binary names resolve from `config :barkpark, :studio_chat_probe` — keys
  `:claude_binary`, `:bp_binary`, `:codex_binary`. When unset, `:claude` falls
  back to the SAME binary the chat spawns (`config :barkpark, :claude_chat,
  :binary`, default `"claude"`) so the probe can never point at a different
  claude than the runtime; `:bp`/`:codex` default to `"bp"`/`"codex"`. Tests
  inject a `chmod +x` sh script per lane (VACUOUS-GREEN LAW: the fake emits each
  branch's exact JSON + exit code, so a passing test proves the real parse path).
  """

  @enforce_keys [:provider]
  defstruct provider: nil,
            binary: false,
            path: nil,
            version: nil,
            authed?: nil,
            account: nil,
            ready?: false,
            reason: nil

  @type provider :: :claude | :bp | :codex

  @type t :: %__MODULE__{
          provider: provider(),
          binary: boolean(),
          path: String.t() | nil,
          version: String.t() | nil,
          authed?: boolean() | nil,
          account: map() | nil,
          ready?: boolean(),
          reason: atom() | nil
        }

  @providers [:claude, :bp, :codex]

  # Hard deadline on each claude shell-out (`--version` and `auth status`).
  # `System.cmd` blocks with no timeout, and `kick_readiness_probe` spawns this
  # probe per Studio-chat mount/reconnect with NO dedup — so a stalled `claude
  # auth status` would otherwise leak one orphaned OS child per page load.
  # Config-overridable per env for tests via
  # `config :barkpark, :studio_chat_probe, timeout_ms: N` (same seam as the
  # injectable binary names). Mirrors `studio_chat/titles.ex`'s @cli_timeout_ms.
  @default_timeout_ms 15_000

  @doc """
  Probe one provider lane's readiness. Pure w.r.t. Barkpark state — it only
  reads config + the filesystem/PATH and (for `:claude`) shells out to the CLI.

  Returns a `%Probe{}`; NEVER raises — a CLI that is missing, non-executable, or
  emits garbage degrades to the honest not-ready struct for that lane.

  **Run async** — see the module doc's LATENCY section; `probe(:claude)` can
  cost ~1–2s.
  """
  @spec probe(provider()) :: t()
  def probe(provider) when provider in @providers do
    name = binary_name(provider)

    case System.find_executable(name) do
      nil -> absent(provider)
      path -> present(provider, path)
    end
  end

  # ── present-binary probes (one per lane) ──────────────────────────────────

  defp present(:claude, path) do
    {authed?, account} = claude_auth(path)

    %__MODULE__{
      provider: :claude,
      binary: true,
      path: path,
      version: claude_version(path),
      authed?: authed?,
      account: account,
      ready?: authed?,
      reason: if(authed?, do: nil, else: :not_authenticated)
    }
  end

  # bp: presence/path only. Auth is mint-driven (no login step to probe) — so
  # authed? stays nil (not-applicable), never a misleading false.
  defp present(:bp, path) do
    %__MODULE__{
      provider: :bp,
      binary: true,
      path: path,
      version: nil,
      authed?: nil,
      account: nil,
      ready?: true
    }
  end

  defp present(:codex, path) do
    case Barkpark.StudioChat.Runtime.Codex.Readiness.probe(path, %{timeout_ms: probe_timeout()}) do
      {:ok, readiness} ->
        struct!(__MODULE__, Map.merge(readiness, %{provider: :codex}))

      {:error, reason} ->
        %__MODULE__{
          provider: :codex,
          binary: true,
          path: path,
          authed?: false,
          ready?: false,
          reason: reason
        }
    end
  end

  # ── absent-binary structs ─────────────────────────────────────────────────

  # bp's authed? is not-applicable in BOTH states (mint-driven).
  defp absent(:bp), do: %__MODULE__{provider: :bp, binary: false, reason: :binary_missing}

  defp absent(provider),
    do: %__MODULE__{provider: provider, binary: false, authed?: false, reason: :binary_missing}

  # ── claude shell-outs (tolerant; degrade on any error) ────────────────────

  # `claude --version` works with zero credentials, e.g. "2.1.207 (Claude Code)".
  # We surface the semver token when we can recognise it, else the raw trimmed
  # line, else nil.
  defp claude_version(path) do
    case run(path, ["--version"]) do
      {out, 0} -> parse_version(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_version(out) do
    trimmed = String.trim(out)

    case Regex.run(~r/\d+(?:\.\d+)+\S*/, trimmed) do
      [version | _] -> version
      nil -> if trimmed == "", do: nil, else: trimmed
    end
  end

  # `claude auth status --json`: exit 0 + loggedIn:true ⇒ authed with account;
  # ANYTHING else (exit 1, loggedIn:false, non-JSON, crash) ⇒ {false, nil}.
  # Expired == never here BY DESIGN (charter D2 — indistinguishable shapes).
  defp claude_auth(path) do
    with {out, 0} <- run(path, ["auth", "status", "--json"]),
         {:ok, %{"loggedIn" => true} = json} <- Jason.decode(String.trim(out)) do
      {true, account(json)}
    else
      _ -> {false, nil}
    end
  rescue
    _ -> {false, nil}
  end

  defp account(json) do
    %{
      email: json["email"],
      org: json["orgName"],
      subscription: json["subscriptionType"],
      method: json["authMethod"]
    }
  end

  # Bounded CLI one-shot. `claude --version` / `claude auth status` block with no
  # timeout; Task.yield waits up to the deadline and Task.shutdown brutal-kills a
  # child that runs past it, so a wedged CLI returns a named error atom instead of
  # hanging the probe (and leaking the OS child). Callers degrade the atom to the
  # honest not-ready struct. Mirrors `studio_chat/titles.ex` per-site — no shared
  # abstraction. `async_nolink` (via the app's TaskSupervisor) so a shell-out that
  # crashes surfaces as `{:exit, _}` here rather than taking the probe down.
  #
  # Sobelow CI.System is a false-positive: `path` is resolved by
  # `System.find_executable/1` in `probe/1` (a fixed binary-name lookup or a
  # test-only config override, never request data) and `args` is a fixed token
  # list — no shell string, no client input. This inline skip replaces the
  # line-anchored `.sobelow-skips` fingerprint (`probe.ex:197`) that the deadline
  # wrapper moved System.cmd off of.
  # sobelow_skip ["CI.System"]
  defp run(path, args) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        System.cmd(path, args, stderr_to_stdout: false)
      end)

    case Task.yield(task, probe_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :probe_crashed}
      nil -> {:error, :probe_timeout}
    end
  end

  defp probe_timeout, do: probe_cfg(:timeout_ms) || @default_timeout_ms

  # ── config-injectable binary names ────────────────────────────────────────

  defp binary_name(:claude), do: probe_cfg(:claude_binary) || claude_chat_binary()
  defp binary_name(:bp), do: probe_cfg(:bp_binary) || "bp"
  defp binary_name(:codex), do: probe_cfg(:codex_binary) || "codex"

  defp probe_cfg(key) do
    :barkpark
    |> Application.get_env(:studio_chat_probe, [])
    |> Keyword.get(key)
  end

  # Default claude binary = the one the chat runtime actually spawns, read from
  # the same config key (no module dependency on BarkparkWeb, keeping this core
  # module layer-clean).
  defp claude_chat_binary do
    :barkpark
    |> Application.get_env(:claude_chat, [])
    |> Keyword.get(:binary, "claude")
  end
end
