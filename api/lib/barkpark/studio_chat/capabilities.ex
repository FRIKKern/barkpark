defmodule Barkpark.StudioChat.Runtime.Capabilities do
  @moduledoc """
  The provider-capability matrix for a Studio chat runtime (epic
  studio-claude-chat, wave 12, charter D66).

  ONE struct that centralises every place the chat encodes "what THIS binary can
  do" — the scattered binary-divergence knowledge that today lives as bare
  literals across three files. The matrix is DATA ONLY (no behaviour), so a UI
  feature reads a FLAG instead of assuming Claude, and wiring the struct in is
  byte-identical to the literals it replaces (the no-tax golden proves it).

  ## The divergence knowledge it centralises

    * **Agent-vs-Task spawn names** — `chat_tool_renderer.ex`'s `@spawn_names`
      now SOURCES `agent_spawn_names/1`. The wire has shipped both forms: vanilla
      `claude` emits `Task`, the cmux fork emits `Agent` (charter D40). The
      renderer still dispatches on SHAPE too (`spawn_shape?/1`); the capability
      records the NAME set a given provider is known to use.

    * **TodoWrite absence** — `studio_chat.ex`'s `todo_shaped?/1` dispatches on
      SHAPE precisely because the tool NAME is host-binary-dependent: the cmux
      binary lacks TodoWrite entirely, vanilla ships it (charter D39). The
      `todo_write` flag records whether the runtime is known to expose the tool
      AT ALL — the shape router stays the runtime dispatch, the flag is the
      declared expectation.

    * **`initialize` slash-command list** — `claude_chat.ex`'s `initialize/1`
      asks the binary for `response.commands` right after spawn (charter D36a).
      Whether a runtime answers that handshake is the `slash_commands`
      capability, not a hard assumption baked into the composer.

  Every field mirrors a vocabulary or seam that already exists in the runtime;
  `claude/0` reads the SAME source values (`Session.@modes`,
  `ClaudeChat.@models/@efforts`, the `@spawn_names` set) so the struct cannot
  silently diverge from the code it describes.

  `claude/0` is the one constructor today (the live Anthropic `claude` binary). A
  future provider (Codex, a local model) gets its own constructor and the UI —
  reading flags — degrades honestly instead of pretending Claude.
  """

  @typedoc "How the runtime surfaces model reasoning: inline text, token counts only, or not at all."
  @type thinking :: :text | :tokens | :none

  @typedoc "How plan mode is enforced: a native permission gate, a simulated prompt, or absent."
  @type plan :: :native_gate | :simulated | :none

  @typedoc "How sub-agent runs are shown: a full journey tree, flat rows, or not at all."
  @type agent_rail :: :full_tree | :rows | :none

  @type t :: %__MODULE__{
          provider: atom(),
          modes: [String.t()],
          danger_mode: String.t() | nil,
          models: [String.t()],
          efforts: [String.t()],
          thinking: thinking(),
          plan: plan(),
          agent_rail: agent_rail(),
          slash_commands: boolean(),
          mode_switch: boolean(),
          rewind: boolean(),
          images: boolean(),
          mcp_tools: boolean(),
          agent_spawn_names: [String.t()],
          todo_write: boolean(),
          user_input: boolean()
        }

  @enforce_keys [:provider]
  defstruct provider: nil,
            # Permission-mode vocabulary the runtime accepts (mirror of Session.@modes).
            modes: [],
            # The one mode inside `modes` that removes every gate (the armed ceremony).
            danger_mode: nil,
            # Model aliases the picker offers (mirror of ClaudeChat.@models).
            models: [],
            # Reasoning-effort tiers (mirror of ClaudeChat.@efforts).
            efforts: [],
            # Reasoning surface: :text | :tokens | :none.
            thinking: :none,
            # Plan-mode enforcement: :native_gate | :simulated | :none.
            plan: :none,
            # Agent-run rail: :full_tree | :rows | :none.
            agent_rail: :none,
            # Answers the `initialize` handshake with a slash-command list (D36a).
            slash_commands: false,
            # Accepts `set_permission_mode` mid-session (D12) instead of a respawn.
            mode_switch: false,
            # Message-granular rewind / `--fork-session` resume (probe: scc-w12-fork-probe).
            rewind: false,
            # Accepts pasted/dropped images as base64 content blocks (D25).
            images: false,
            # Bridges an MCP loopback server (`--mcp-config`; scc-w12-mcp-loopback, D63/D64).
            mcp_tools: false,
            # Sub-agent spawn tool NAMES this runtime is known to emit (D40).
            agent_spawn_names: [],
            # Exposes the TodoWrite tool at all (shape router still dispatches; D39).
            todo_write: false,
            # Surfaces an interactive user-input / AskUserQuestion seam (D31).
            user_input: false

  @doc """
  Capabilities of the live Anthropic `claude` binary — the one provider today.

  Every list mirrors the runtime's own source of truth so the matrix cannot
  drift from the code it describes:

    * `modes`  ← `Barkpark.StudioChat.Session.modes/0`
    * `models` ← `BarkparkWeb.Studio.ClaudeChat.models/0`
    * `efforts` ← `BarkparkWeb.Studio.ClaudeChat.efforts/0`

  `agent_spawn_names` is the `Task`/`Agent` set that `chat_tool_renderer.ex`
  sources back OUT of here (`@spawn_names`), closing the loop.
  """
  @spec claude() :: t()
  def claude do
    %__MODULE__{
      provider: :claude,
      modes: ~w(plan acceptEdits auto dontAsk manual bypassPermissions),
      danger_mode: "bypassPermissions",
      models: ~w(haiku sonnet opus fable),
      efforts: ~w(low medium high xhigh max),
      thinking: :text,
      plan: :native_gate,
      agent_rail: :full_tree,
      slash_commands: true,
      mode_switch: true,
      # No message-granular rewind UI ships yet — scc-w12-fork-probe writes the
      # verdict, not the surface. Honest false until that lands.
      rewind: false,
      images: true,
      mcp_tools: true,
      agent_spawn_names: ~w(Task Agent),
      todo_write: true,
      user_input: true
    }
  end

  @doc """
  Capabilities of the pinned Codex app-server runtime. Only schema-backed
  surfaces are advertised; Claude-specific mode switching, slash commands,
  rewind, TodoWrite, and named agent spawns remain disabled.
  """
  @spec codex() :: t()
  def codex do
    %__MODULE__{
      provider: :codex,
      modes: [],
      danger_mode: nil,
      models: [],
      efforts: [],
      thinking: :text,
      plan: :simulated,
      agent_rail: :rows,
      slash_commands: false,
      mode_switch: false,
      rewind: false,
      images: true,
      mcp_tools: true,
      agent_spawn_names: [],
      todo_write: false,
      user_input: false
    }
  end

  @doc """
  The sub-agent spawn tool names for this runtime (charter D40) — the value
  `chat_tool_renderer.ex`'s `@spawn_names` sources at compile time.
  """
  @spec agent_spawn_names(t()) :: [String.t()]
  def agent_spawn_names(%__MODULE__{agent_spawn_names: names}), do: names
end
