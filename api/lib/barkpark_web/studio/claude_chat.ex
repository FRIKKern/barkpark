defmodule BarkparkWeb.Studio.ClaudeChat do
  @moduledoc """
  The WEB-side adapter for the Studio **Claude chat** (`/studio/chat`).

  The engine moved to `Barkpark.StudioChat.Provider.Claude` (core) —
  task-ad931ba2e0d0bdf4. It had to: `Barkpark.StudioChat.Runtime`,
  `Runtime.Claude`, `Runtime.Codex.Session` and the Recorder all drove provider
  sessions through this module, so a core process could not run without the web
  layer compiled and the detached/API/background transports inherited a
  presentation dependency they never wanted.

  What stayed WEB-only is the part that genuinely is web: **route gating** — the
  `/studio/chat` route rides the `:admin_studio` live_session, and the nav tab is
  shown only to admins (`StudioChrome.shares_admin?`) — and **rendering**
  (`ChatLive`, `ChatToolRenderer`). Neither is delegated from here; both live at
  their own call sites.

  What is left in this module is a NAME. Every function below is a
  `defdelegate` to the core provider, kept so the ~430 existing call sites and
  tests that say `ClaudeChat.f(...)` keep working unchanged; the three trust
  controls the engine enforces (admin-only route, public-demo hard refuse in
  `enabled?/0`, `BARKPARK_CLAUDE_CHAT=0` per-host opt-out) are documented and
  implemented there.

  New code should call `Barkpark.StudioChat.Provider.Claude` directly. Nothing
  under `Barkpark.StudioChat.*` may call THIS module — the layering tripwire
  (`test/barkpark/studio_chat/core_web_layering_tripwire_test.exs`) reds if it
  ever does again.
  """

  alias Barkpark.StudioChat.Provider.Claude

  # ── gate + configuration ──────────────────────────────────────────────────
  defdelegate enabled?(), to: Claude
  defdelegate binary(), to: Claude
  defdelegate max_buffer_bytes(), to: Claude
  defdelegate cwd(), to: Claude
  defdelegate sandbox_runner(), to: Claude

  # ── spawn command + argv ──────────────────────────────────────────────────
  defdelegate command(mode \\ "plan", session_opts \\ %{}), to: Claude
  defdelegate build_args(mode, session_opts \\ %{}), to: Claude
  defdelegate cloud_build_args(mode, session_opts \\ %{}), to: Claude
  defdelegate execution_profile(), to: Claude
  defdelegate execution_profile(session_opts), to: Claude
  defdelegate resolve_workspace_execution_profile(session_opts), to: Claude

  # ── vocabulary (models / efforts / modes) ─────────────────────────────────
  defdelegate models(), to: Claude
  defdelegate efforts(), to: Claude
  defdelegate modes(), to: Claude
  defdelegate normalize_model(value), to: Claude
  defdelegate normalize_effort(value), to: Claude
  defdelegate normalize_mode(value), to: Claude

  # ── MCP ───────────────────────────────────────────────────────────────────
  defdelegate mcp_tool?(name), to: Claude
  defdelegate mcp_tool_name(name), to: Claude
  defdelegate mcp_auto_approved?(name), to: Claude
  defdelegate mcp_connected?(event), to: Claude
  defdelegate mcp_config(raw_token), to: Claude
  defdelegate mcp_config(raw_token, tool_descriptors), to: Claude
  defdelegate mcp_api_url(), to: Claude

  # ── event predicates ──────────────────────────────────────────────────────
  defdelegate auth_failure?(event), to: Claude
  defdelegate result_success?(event), to: Claude
  defdelegate parse_chunk(buffer, chunk), to: Claude

  # ── spawn env + task credentials ──────────────────────────────────────────
  defdelegate mint_refused_sentinel(), to: Claude
  defdelegate scrubbed_env_names(), to: Claude
  defdelegate intentional_env_passthrough_names(), to: Claude
  defdelegate spawn_env(raw_token, worker_id), to: Claude
  defdelegate worker_id(session_id), to: Claude
  defdelegate task_hands(session), to: Claude
  defdelegate task_token_ttl_opts(), to: Claude
  defdelegate task_token_renew_skew_s(), to: Claude
  defdelegate task_token_check_ms(), to: Claude
  defdelegate task_token_renew_cooldown_s(), to: Claude
  defdelegate token_phase(expires_at), to: Claude
  defdelegate renew_task_token(session), to: Claude

  # ── session lifecycle ─────────────────────────────────────────────────────
  defdelegate start_session(opts), to: Claude
  defdelegate initialize(session), to: Claude
  defdelegate adopt_sink(session, new_sink), to: Claude
  defdelegate send_message(session, content), to: Claude
  defdelegate respond_permission(session, request_id, decision), to: Claude
  defdelegate interrupt(session), to: Claude
  defdelegate set_permission_mode(session, mode), to: Claude
  defdelegate set_model(session, model), to: Claude
  defdelegate close(session), to: Claude
end
