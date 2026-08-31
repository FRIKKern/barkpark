defmodule Barkpark.Plugins.Capabilities do
  @moduledoc """
  Assembles the `/v1/capabilities` manifest (M1).

  Two responsibilities, split so the projection is unit-testable without the
  app or the DB:

    * `manifest/1` / `manifest/2` — assemble the FULL superset manifest map by
      folding `Registry.all/0` + `Registry.collect_routes/1` +
      `Registry.collect_cli_commands/1` + a small hand-maintained core-verb
      registry. Emits EXACTLY the frozen `manifest.schema.json` fields. This
      touches the registry (and so the running app), but performs no DB reads.
    * `project/2` — a PURE function `(manifest_map, caller_tier) -> manifest_map`
      applying the default-deny existence-hiding allow-list (contract rule #1).
      No app, no DB, no registry — fully unit-testable in isolation.

  The contract this binds to is `docs/cli/manifest.schema.json` and the M0
  decisions in `docs/cli/m0-decisions.md` (Part C rules — esp. existence-hiding
  and the `scoped_admin` caveat).

  ## Auth-tier ladder

  The six closed tiers (`docs/cli/manifest.schema.json#/$defs/auth_tier`) split
  into a totally-ordered GLOBAL ladder used by `project/2`'s default-deny
  visibility test, plus two side channels (`scoped_admin`, `ingest`) that are
  NOT on the global ladder:

      none < read < write < admin

  * `none` — the existence-hiding floor an anonymous caller sees.
  * `read` / `write` / `admin` — global token tiers; a caller may see a command
    iff the caller's global tier is >= the command's required global tier.
  * `scoped_admin` — per-workspace role (`RequireWorkspaceRole`). NEVER blanket
    client-side denied (contract rule #2): only the server knows the caller's
    per-workspace role, so a `scoped_admin` command is visible to any caller
    that holds at least a global `read` tier (i.e. an authenticated token that
    MIGHT carry a per-workspace role) — but hidden from a truly anonymous
    (`none`) caller, since an anon principal can hold no workspace role.
  * `ingest` — shared-secret ingest token (`RequireIngestToken`), a distinct
    credential from the api_tokens ladder. Treated as an admin-equivalent
    secret: visible only to an `admin` (or `ingest`) caller, never to anon.
  """

  alias Barkpark.Plugins.Registry

  @typedoc "The six closed auth tiers from the frozen schema enum."
  @type tier :: String.t()

  # Global ladder rank. Higher = more authority. `scoped_admin` / `ingest`
  # are NOT on this ladder — they are handled by `visible?/2` side branches.
  @global_rank %{
    "none" => 0,
    "read" => 1,
    "write" => 2,
    "admin" => 3
  }

  @manifest_version "1"

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Assemble the FULL superset manifest map for `caller_tier` (echoed as the
  top-level `auth_tier`), then PROJECT it through the existence-hiding
  allow-list so the returned map is what that caller may see.

  `manifest/1` is `manifest(caller_tier)`; the un-projected superset is
  available via `manifest(caller_tier, project: false)` for golden-diff tests.

  Options:
    * `:project` — when `false`, returns the un-projected superset (still with
      `auth_tier` echoing `caller_tier`). Defaults to `true`.
    * `:server` — override the `server` block (a map). Defaults to
      `default_server/0` (read from app config).
    * `:generated_at` — override the RFC-3339 timestamp string. Defaults to now.
  """
  @spec manifest(tier()) :: map()
  @spec manifest(tier(), keyword()) :: map()
  def manifest(caller_tier, opts \\ []) when is_binary(caller_tier) and is_list(opts) do
    superset = build_superset(caller_tier, opts)

    if Keyword.get(opts, :project, true) do
      project(superset, caller_tier)
    else
      superset
    end
  end

  @doc """
  PURE existence-hiding projection: `(manifest_map, caller_tier) -> manifest_map`.

  Default-deny allow-list keyed on the caller's tier (contract rule #1):

    * a command is kept only when `visible?(command.auth_tier, caller_tier)`;
    * a noun is kept only when it retains >= 1 visible command (so an anon
      caller learns zero admin noun NAMES, not just zero admin commands);
    * the top-level `auth_tier` is overwritten with `caller_tier` (the echo);
    * the `etag` is recomputed over the projected body so it varies by tier.

  No app, no DB, no registry access — safe to call on any plain map.
  """
  @spec project(map(), tier()) :: map()
  def project(%{} = manifest, caller_tier) when is_binary(caller_tier) do
    # The rank the caller is ranked by; the `+chat` capability (if any) rides
    # alongside and is consulted ONLY by the orthogonal chat side-branch.
    base = base_tier(caller_tier)
    commands = Map.get(manifest, "commands", [])
    nouns = Map.get(manifest, "nouns", [])

    visible_commands =
      Enum.filter(commands, fn cmd ->
        visible?(command_tier(cmd), base) or chat_visible?(cmd, caller_tier)
      end)

    visible_noun_names =
      visible_commands
      |> Enum.map(&command_noun/1)
      |> MapSet.new()

    visible_nouns =
      Enum.filter(nouns, fn noun -> MapSet.member?(visible_noun_names, noun_name(noun)) end)

    projected =
      manifest
      |> Map.put("auth_tier", base)
      |> Map.put("nouns", visible_nouns)
      |> Map.put("commands", visible_commands)

    Map.put(projected, "etag", etag_for(projected))
  end

  @doc """
  True when a caller at `caller_tier` may invoke a command whose REQUIRED tier
  is `required_tier`. The default-deny visibility predicate. Pure.

  Rules (see moduledoc "Auth-tier ladder"):

    * global tiers (`none/read/write/admin`): caller rank >= required rank;
    * `scoped_admin`: visible to any caller above `none` (rule #2 — never
      blanket-deny a token that MIGHT hold a per-workspace role);
    * `ingest`: visible only to an `admin`/`ingest` caller (never to anon).
  """
  @spec visible?(tier(), tier()) :: boolean()
  def visible?(required_tier, caller_tier)

  # Caller holding the ingest secret can see everything an admin can, plus ingest.
  def visible?(_required, "ingest"), do: true

  def visible?("scoped_admin", caller_tier),
    do: caller_rank(caller_tier) >= @global_rank["read"]

  def visible?("ingest", caller_tier),
    do: caller_rank(caller_tier) >= @global_rank["admin"]

  def visible?(required_tier, caller_tier) do
    case Map.fetch(@global_rank, required_tier) do
      {:ok, required_rank} -> caller_rank(caller_tier) >= required_rank
      # Unknown required tier → default-deny.
      :error -> false
    end
  end

  @doc """
  Resolve a caller's auth tier from a conn's resolved token assign. Used by
  the capabilities controller. NOT pure (reads the token struct), kept out of
  `project/2`'s pure path.

  An absent / nil token is `"none"`. A present token maps to the highest
  global tier its permissions satisfy: `admin` > `write` > `read`.

  D36 (charter D16) — `chat` is an ORTHOGONAL capability, NOT a rank. A
  workspace-bound token carrying the `chat` permission but no doc/task tier
  may still DISCOVER the `chat` noun. That capability rides ALONGSIDE the base
  tier as a `"<base>+chat"` suffix (e.g. `"none+chat"`, `"read+chat"`) so it
  lifts nothing else: the base rank is unchanged, and `project/2` splits the
  suffix off before ranking. This mirrors `RequireChatAccess.chat_scope/1`
  (admin is already covered by the base tier; the added case is the non-admin,
  workspace-bound `chat` token that the runtime authorizes at `{:workspace,_}`).
  """
  @spec tier_for_token(struct() | nil) :: tier()
  def tier_for_token(nil), do: "none"

  def tier_for_token(token) do
    alias Barkpark.Tenancy.Auth, as: TenancyAuth

    base =
      cond do
        TenancyAuth.permits?(token, :admin) -> "admin"
        TenancyAuth.permits?(token, :write) -> "write"
        TenancyAuth.permits?(token, :read) -> "read"
        true -> "none"
      end

    # A global-admin caller already discovers `chat` through the rank ladder;
    # the suffix is only for the non-admin, workspace-bound `chat` token —
    # exactly the principal RequireChatAccess authorizes at `{:workspace, ws}`.
    if base != "admin" and Barkpark.Auth.has_permission?(token, "chat") and
         not is_nil(Map.get(token, :workspace_id)) do
      base <> "+chat"
    else
      base
    end
  end

  # The doc/task RANK carried by a (possibly `+chat`-suffixed) caller tier. The
  # orthogonal `chat` capability rides alongside the rank and never lifts it, so
  # every rank comparison and the echoed `auth_tier` use the base alone.
  @spec base_tier(tier()) :: tier()
  def base_tier(caller_tier) when is_binary(caller_tier) do
    case :binary.split(caller_tier, "+") do
      [base | _] -> base
      _ -> caller_tier
    end
  end

  # True when the caller may DISCOVER the orthogonal `chat` noun: an explicit
  # `+chat` capability suffix, OR a global-admin/ingest caller (who already sees
  # every noun through the normal rank ladder). This is the ONLY orthogonal
  # grant — it widens visibility for `noun == "chat"` and nothing else.
  @spec chat_cap?(tier()) :: boolean()
  defp chat_cap?(caller_tier) when is_binary(caller_tier) do
    String.contains?(caller_tier, "+chat") or base_tier(caller_tier) in ["admin", "ingest"]
  end

  # ── Superset assembly ────────────────────────────────────────────────────

  defp build_superset(caller_tier, opts) do
    server = Keyword.get(opts, :server, default_server())

    generated_at =
      Keyword.get(opts, :generated_at, DateTime.utc_now() |> DateTime.to_iso8601())

    # Plugin set + the routes they mounted (folded in as a path-sanity
    # cross-check — see §4.2 of the contract). collect_routes/1 is called for
    # its side-of-truth value even though v1 does not strip on it.
    plugins = safe_registry(fn -> Registry.all() end, [])
    _routes = safe_registry(fn -> Registry.collect_routes(%{}) end, [])
    plugin_commands_raw = safe_registry(fn -> Registry.collect_cli_commands([]) end, [])

    {plugin_module_to_name, _} =
      Enum.reduce(plugins, {%{}, nil}, fn entry, {acc, _} ->
        {Map.put(acc, entry.module, entry.name), nil}
      end)

    # Stamp provenance on every plugin-contributed command. Plugins do NOT
    # self-declare `source`; we derive `plugin:<name>` from the owning plugin.
    # collect_cli_commands/1 returns a flat list with no module tag, so we
    # match each command's `noun` back to a plugin that declares that noun in
    # its manifest. When that mapping is ambiguous/absent we fall back to a
    # bare `plugin` tag so provenance is never silently dropped.
    plugin_noun_to_name = plugin_noun_index(plugins)

    plugin_commands =
      Enum.map(plugin_commands_raw, fn cmd ->
        cmd = normalize_command(cmd)
        name = Map.get(plugin_noun_to_name, cmd["noun"])
        source = if name, do: "plugin:#{name}", else: "plugin"
        Map.put(cmd, "source", source)
      end)

    core_nouns = core_nouns()
    core_commands = core_commands()

    plugin_nouns = plugin_nouns(plugins, plugin_commands)

    _ = plugin_module_to_name

    # Echo the base rank only — the orthogonal `+chat` capability suffix never
    # appears on the wire (it is an internal projection input, not a tier).
    base = base_tier(caller_tier)

    %{
      "manifest_version" => @manifest_version,
      "server" => server,
      "auth_tier" => base,
      "generated_at" => generated_at,
      "etag" => "",
      "nouns" => core_nouns ++ plugin_nouns,
      "commands" => core_commands ++ plugin_commands
    }
    |> maybe_put_build(base, opts)
    |> maybe_gate_views(opts)
    |> maybe_gate_chat(base, opts)
    |> maybe_gate_bpml(base, opts)
    |> then(fn m -> Map.put(m, "etag", etag_for(m)) end)
  end

  # The root `bpml` vocabulary key (BPML masterplan W0): the block-tag →
  # allowed-attributes grammar, the inline alias→mark table, and a derived
  # digest clients echo to detect stale generated types. STRICTLY OPT-IN
  # (`include_bpml: true`, wired from `?bpml=1`) for the same reason
  # `build`/`views`/`chat` are: released bp binaries strict-decode the manifest
  # root, so an unconditional new root key would brick every CLI in the wild.
  # NOT withheld from tier "none": the vocabulary describes the public paper
  # format, not any capability of this instance — same class as the reader.
  defp maybe_gate_bpml(manifest, _caller_tier, opts) do
    if Keyword.get(opts, :include_bpml, false) do
      Map.put(manifest, "bpml", Barkpark.PortableDoc.Bpml.vocabulary())
    else
      manifest
    end
  end

  # Build identity (compile-time constants — see Barkpark.BuildInfo) is
  # STRICTLY OPT-IN (`include_build: true`, wired from `?build=1`): every
  # released bp binary parses the manifest with DisallowUnknownFields, so an
  # unconditional new root key would brick every CLI already in the wild.
  # Also withheld from anonymous callers — tier "none" gets no commit sha.
  # When included it deliberately feeds etag_for/1: the values are stable
  # per build, so the etag stays stable within a build and changes on a new
  # one (desired — clients re-fetch the manifest after a deploy).
  defp maybe_put_build(manifest, caller_tier, opts) do
    if Keyword.get(opts, :include_build, false) and caller_tier != "none" do
      Map.put(manifest, "build", Barkpark.BuildInfo.info())
    else
      manifest
    end
  end

  # The frozen command-level `views` descriptor (wave axi-brief-views): the
  # commands that support a token-thrifty brief projection (task.ready,
  # task.prime, search.query) DECLARE it inline in their command maps, but the
  # key is STRICTLY OPT-IN on the wire (`include_views: true`, wired from
  # `?views=1`) for the same reason `build` is: every released bp binary parses
  # the manifest with DisallowUnknownFields, which recurses into each Command,
  # so an unconditional new command-level key would brick every CLI already in
  # the wild. Without the opt-in we strip every declared `views` key back out,
  # yielding a body byte-identical to the pre-views contract (etag included).
  # The descriptor shape (`supported`/`default`/`default_for_agents`) is frozen
  # for this wave — see `agent_views_descriptor/0`.
  defp maybe_gate_views(manifest, opts) do
    if Keyword.get(opts, :include_views, false) do
      manifest
    else
      Map.update(manifest, "commands", [], fn commands ->
        Enum.map(commands, &Map.delete(&1, "views"))
      end)
    end
  end

  # The root `chat` capability-discovery key (charter D27, wave t3code): the
  # per-provider picker vocabulary %{"providers" => %{"<provider>" =>
  # %{"modes", "models", "efforts"}}} sourced from Runtime.capabilities/1 —
  # codex ships empty arrays TODAY, so clients must degrade, never assume.
  # STRICTLY OPT-IN (`include_chat: true`, wired from `?chat=1`) for the same
  # reason `build`/`views` are: released bp binaries strict-decode the manifest
  # root, so an unconditional new root key would brick every CLI in the wild.
  # Withheld from tier "none" exactly like maybe_put_build — an anonymous
  # caller discovers nothing about the chat surface. Sits BEFORE the etag step
  # so the gated key feeds etag_for/1 (chat and non-chat bodies get distinct
  # etags; no 304 cross-contamination).
  defp maybe_gate_chat(manifest, caller_tier, opts) do
    if Keyword.get(opts, :include_chat, false) and caller_tier != "none" do
      Map.put(manifest, "chat", %{"providers" => chat_provider_caps()})
    else
      manifest
    end
  end

  # One entry per registered provider. The advertised `modes` EXCLUDE the
  # provider's danger mode (bypassPermissions): the /v1/chat transport
  # categorically rejects it (D22 — the armed ceremony is not representable
  # remotely), so advertising it would bait every picker into a guaranteed 400.
  defp chat_provider_caps do
    Map.new(Barkpark.StudioChat.Session.providers(), fn provider ->
      caps = Barkpark.StudioChat.Runtime.capabilities(provider)

      {provider,
       %{
         "modes" => (Map.get(caps, :modes) || []) -- [Map.get(caps, :danger_mode)],
         "models" => Map.get(caps, :models) || [],
         "efforts" => Map.get(caps, :efforts) || []
       }}
    end)
  end

  @doc """
  The frozen command-level `views` descriptor a command declares when it
  supports the brief/full projection (wave axi-brief-views): brief is the
  token-thrifty card an agent gets by default; full is the escape hatch a human
  gets by default. Commands WITHOUT this descriptor are full-only forever
  (task.get / `bp task show` intentionally omit it — they ARE the escape hatch).

  Kept as a single source of truth so the tasks plugin (`task.ready`,
  `task.prime`) and the core `search.query` command declare the byte-identical
  shape; the contract test pins all three to this map.
  """
  @spec agent_views_descriptor() :: map()
  def agent_views_descriptor do
    %{
      "supported" => ["brief", "full"],
      "default" => "full",
      "default_for_agents" => "brief"
    }
  end

  # Map each plugin's declared noun(s) → plugin name, for provenance stamping.
  # A plugin's manifest MAY declare nouns under "nouns" (list of maps or
  # strings); when absent, fall back to the plugin slug itself as a noun token.
  defp plugin_noun_index(plugins) do
    Enum.reduce(plugins, %{}, fn entry, acc ->
      nouns = manifest_nouns(entry.manifest) ++ [entry.name]

      Enum.reduce(nouns, acc, fn n, inner ->
        Map.put_new(inner, n, entry.name)
      end)
    end)
  end

  defp manifest_nouns(%{"nouns" => nouns}) when is_list(nouns) do
    Enum.flat_map(nouns, fn
      n when is_binary(n) -> [n]
      %{"name" => n} when is_binary(n) -> [n]
      _ -> []
    end)
  end

  defp manifest_nouns(_), do: []

  # Derive one noun entry per plugin that contributes >= 1 command, tagged
  # `plugin: <name>`. Deduped by noun name; summary falls back to the plugin
  # manifest's description when present.
  defp plugin_nouns(plugins, plugin_commands) do
    name_to_entry = Map.new(plugins, fn e -> {e.name, e} end)

    plugin_commands
    |> Enum.group_by(fn cmd -> {cmd["noun"], source_plugin_name(cmd)} end)
    |> Enum.map(fn {{noun, plugin_name}, _cmds} ->
      summary =
        case Map.get(name_to_entry, plugin_name) do
          %{manifest: %{"description" => d}} when is_binary(d) and d != "" -> d
          %{manifest: %{"summary" => s}} when is_binary(s) and s != "" -> s
          _ -> "#{noun} — plugin-contributed commands."
        end

      %{
        "name" => noun,
        "summary" => summary,
        "plugin" => plugin_name
      }
    end)
    |> Enum.uniq_by(& &1["name"])
    |> Enum.sort_by(& &1["name"])
  end

  defp source_plugin_name(cmd) do
    case Map.get(cmd, "source") do
      "plugin:" <> name -> name
      _ -> nil
    end
  end

  # Normalize a plugin-supplied command (atom-keyed cli_command()) into the
  # string-keyed wire shape the manifest emits, recursively for http/args/flags.
  defp normalize_command(cmd) when is_map(cmd) do
    cmd
    |> stringify_shallow()
    |> Map.update("http", %{}, &stringify_shallow/1)
    |> Map.update("args", [], fn args -> Enum.map(args || [], &stringify_shallow/1) end)
    |> Map.update("flags", [], fn flags -> Enum.map(flags || [], &stringify_shallow/1) end)
  end

  defp stringify_shallow(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_shallow(other), do: other

  # ── Field accessors (string-keyed wire shape) ─────────────────────────────

  defp command_tier(%{"auth_tier" => t}) when is_binary(t), do: t
  defp command_tier(_), do: "admin"

  defp command_noun(%{"noun" => n}) when is_binary(n), do: n
  defp command_noun(_), do: nil

  # Orthogonal chat side-branch (D36 / charter D16). The nine `chat.*` commands
  # DECLARE `auth_tier: "admin"` (unchanged — admin/ingest keep discovering them
  # through the rank ladder), but a caller holding the `chat` capability ALSO
  # discovers the `chat` noun. This is a capability grant, not a rank lift: it
  # widens visibility for `noun == "chat"` ONLY, so no other noun's tier moves.
  defp chat_visible?(cmd, caller_tier) do
    command_noun(cmd) == "chat" and chat_cap?(caller_tier)
  end

  defp noun_name(%{"name" => n}) when is_binary(n), do: n
  defp noun_name(_), do: nil

  defp caller_rank(tier), do: Map.get(@global_rank, tier, 0)

  # ── ETag ───────────────────────────────────────────────────────────────

  # Content-addressed ETag over the projected body. Excludes the etag field
  # itself (which is being computed) and `generated_at` (a timestamp would
  # make the etag change every request, defeating 304). Weak validator form.
  defp etag_for(manifest) do
    payload =
      manifest
      |> Map.drop(["etag", "generated_at"])
      |> :erlang.term_to_binary()

    digest =
      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "W/\"caps-#{digest}\""
  end

  # ── Server identity ──────────────────────────────────────────────────────

  @doc """
  The boot-time `server` envelope: `name`, `version`, `base_url`, `api_version`,
  `min_cli`. `base_url` defaults to the frozen `:capabilities_base_url` app-env
  scalar (set once at `runtime.exs` from `PHX_HOST`).

  Public so the controller can compose a per-request override — deriving
  `base_url` from the caller's actual request Host — and thread it back through
  `manifest/2`'s existing `:server` option. The envelope KEYS are fixed
  (`manifest.schema.json` is `additionalProperties: false` and the Go client
  strict-decodes it): only the `base_url` VALUE may be swapped, never a new key.
  """
  @spec default_server() :: %{optional(String.t()) => String.t()}
  def default_server do
    %{
      "name" => app_env(:capabilities_server_name, "barkpark"),
      "version" => server_version(),
      "base_url" => app_env(:capabilities_base_url, "http://localhost:4000"),
      "api_version" => "1",
      "min_cli" => "1.0.0"
    }
  end

  defp server_version do
    case Application.spec(:barkpark, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  defp app_env(key, default) do
    Application.get_env(:barkpark, key, default)
  end

  # Wrap registry calls so a registry that isn't started (e.g. in a pure
  # `mix run` or a unit test) never crashes manifest assembly.
  defp safe_registry(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  # ── Core verb registry (hand-maintained) ──────────────────────────────────
  #
  # The canonical core nouns (doc, schema, media, search, workspace, webhook,
  # token, plugin, share, graph, auth) + representative commands. Mirrors the
  # frozen fixtures docs/cli/fixtures/core-manifest.json (admin/full view) —
  # which is a curated SUBSET and already omits some core nouns (token, share,
  # graph, auth), so new core nouns do not force a fixture regen.
  # Plugins OFF ⇒ exactly these nouns/commands are emitted. The `task` noun and
  # its `task.*` verbs are NO LONGER core — they moved to the Tasks plugin
  # (`Barkpark.Plugins.Tasks.cli_commands/0`), which the controller stamps with
  # `source: "plugin:tasks"`; and the old `rail` noun is gone entirely.
  #
  # Tiering follows the ROUTER (the code fact behind the schema's auth_tier
  # $comment): the public read surface (`doc get/ls/query`, `search query`,
  # `media ls`) sits behind the `:api` pipeline's OptionalToken (no
  # RequireToken) — genuinely anon-invokable — so it carries `auth_tier:
  # "none"`, the existence-hiding floor. An admin caller (rank above none) still
  # sees every `none` command, so the admin projection stays a superset of the
  # anon projection (matching the fixture PAIRING). Truly gated verbs keep their
  # real tier: write (mutate/upload/webhook.create), admin (`schema get/apply`
  # behind :require_admin, webhook.ls, plugin.ls, plugin.settings), scoped_admin
  # (project-create). NOTE schema.get is admin, not anon: the /v1/schemas scope
  # is :require_admin — public schema discovery rides /api/schemas (legacy),
  # not this verb.
  #
  # Arg-location contract (the manifest arg shape has NO "in"/"location"
  # field — frozen `arg` def is additionalProperties:false). The CLI INFERS
  # where each declared arg goes:
  #   * path  — when the arg name matches a `:placeholder` in http.path_template
  #             (e.g. `doc_id` in `/v1/tasks/:doc_id/claim`).
  #   * query — a GET arg with NO matching path placeholder (e.g. `q` in
  #             search.query).
  #   * body  — a POST/PUT/PATCH arg with no matching path placeholder.
  # If a future verb needs an explicit hint, add an OPTIONAL `"in"` field to
  # the arg in BOTH manifest.schema.json's $defs/arg (additive) and the
  # `arg/4`+`arg/5` builders here, then regenerate the fixtures — keep it
  # additive so existing manifests still validate.

  defp core_nouns do
    [
      %{"name" => "doc", "summary" => "Documents — the content workhorse.", "plugin" => nil},
      %{"name" => "schema", "summary" => "Document type definitions.", "plugin" => nil},
      %{"name" => "media", "summary" => "Assets and collections.", "plugin" => nil},
      %{"name" => "search", "summary" => "Full-text search over documents.", "plugin" => nil},
      %{
        "name" => "workspace",
        "summary" => "Tenancy — workspaces and projects.",
        "plugin" => nil
      },
      # The `dataset.stats` verb (GET /v1/data/analytics/:dataset) is a core
      # command whose noun is `dataset`; declaring the noun here keeps the
      # manifest honest (every command's noun resolves to a declared noun — the
      # invariant `cli_commands_manifest_test` enforces for plugin verbs) and
      # gives the OpenAPI tag a description instead of a dangling reference.
      %{
        "name" => "dataset",
        "summary" => "Dataset-level content stats and overview.",
        "plugin" => nil
      },
      # The `data.counts` verb (GET /v1/data/counts/:dataset) is a core command
      # whose noun is `data` — bundled cross-type reads over the `/v1/data`
      # surface. Declaring the noun keeps the manifest honest (every command's
      # noun resolves to a declared noun — the `capabilities_manifest_test`
      # invariant that dataset.stats' orphaned noun once tripped).
      %{
        "name" => "data",
        "summary" => "Bundled cross-type reads over a dataset (per-type counts).",
        "plugin" => nil
      },
      %{"name" => "webhook", "summary" => "Outbound webhook subscriptions.", "plugin" => nil},
      %{
        "name" => "token",
        "summary" => "Mint read-only, workspace-bound API tokens.",
        "plugin" => nil
      },
      %{
        "name" => "plugin",
        "summary" => "Installed plugins and their settings.",
        "plugin" => nil
      },
      %{
        "name" => "secret",
        "summary" =>
          "Cloud run-secrets — admin-only encrypted store (reveal + rotate at runtime).",
        "plugin" => nil
      },
      %{
        "name" => "share",
        "summary" =>
          "Scoped network shares — expose a workspace/project/dataset surface on the LAN.",
        "plugin" => nil
      },
      # Content graph — CORE, not the Tasks plugin (Goal ges/graph-edge-seam).
      # The graph roots on ANY content doc, so its read verbs are core: they
      # survive the `config :barkpark, :plugins, []` kill switch alongside the
      # CORE-mounted /v1/graph/* routes (fresh-install invariant).
      %{
        "name" => "graph",
        "summary" => "Content graph — traverse references, find orphans + dangling edges.",
        "plugin" => nil
      },
      # Core user auth (login/sessions/MFA/email flows) — CORE, pre-tenant.
      # Routes mount at /v1/auth/* behind the :user_auth pipeline (no api-token,
      # no tenancy). The 5 public verbs are auth_tier "none" (an anon caller must
      # be able to DISCOVER login); the 5 session-gated verbs are "read"
      # (existence-hidden from anon, shown to any authenticated caller). NOTE:
      # the session-gated verbs require a USER session, not an api_token, so bp
      # itself cannot drive them — they are surfaced for discovery/docs.
      %{
        "name" => "auth",
        "summary" => "User accounts — register, login, sessions, MFA.",
        "plugin" => nil
      },
      %{
        "name" => "access",
        "summary" => "Airdrop grants — time-boxed, account-bound scoped access links.",
        "plugin" => nil
      },
      %{
        "name" => "cycle",
        "summary" =>
          "Epic and Legendary cycle ledgers — one project-scoped authority for local and cloud agents.",
        "plugin" => nil
      },
      # Claude chat sessions (charter bp-chat-tui, D21). StudioChat is
      # CORE-embedded, NOT a Barkpark.Plugin — it never flows through
      # plugin_nouns/2, so the noun is hand-declared here so MCP/SDK codegen and
      # any headless harness can DISCOVER chat. The nine non-streaming verbs are
      # registered below; the SSE `GET /v1/chat/sessions/:id/events` route is a
      # builtin carve-out (like `listen`) with no manifest verb — it is NAMED
      # here so a reading agent knows live streaming exists via `bp chat`.
      %{
        "name" => "chat",
        "summary" =>
          "Claude chat sessions — create/list/read/update, send, interrupt, approve, " <>
            "archive/unarchive. " <>
            "Live token streaming rides the `bp chat` SSE events channel " <>
            "(a builtin carve-out, not a manifest verb).",
        "plugin" => nil
      },
      # Mobile app-token exchange, instance half (mobile charter D4/D5/D9,
      # task wb-api-capabilities-undeclared-verbs). DISTINCT noun from `token`
      # above: `token` mints read-only workspace tokens over /v1/tokens;
      # `app_token` mints member-shaped [read,write,chat] tokens over
      # /v1/auth/app-tokens for the Cloud control plane's JIT-provisioned
      # mobile identities. Folding them into one noun would collide two
      # unrelated mint shapes under one verb set.
      %{
        "name" => "app_token",
        "summary" =>
          "Mobile app-token exchange — mint/list/revoke member-shaped, workspace-bound " <>
            "tokens, distinct from `token` (/v1/tokens).",
        "plugin" => nil
      },
      # Personal Dev Fleet support tokens (PDF-D57/D60, task
      # wb-api-capabilities-undeclared-verbs). A write-capable, attributable
      # token for a remote support machine to work the ledger — not the
      # read-only `token` noun's mint.
      %{
        "name" => "fleet_support_token",
        "summary" =>
          "Write-capable per-support ledger tokens for a remote Personal Dev Fleet machine.",
        "plugin" => nil
      },
      # Status-page incident management (task wb-api-capabilities-undeclared-verbs).
      %{
        "name" => "incident",
        "summary" => "Status-page incidents — admin-only create + resolve.",
        "plugin" => nil
      }
    ]
  end

  defp core_commands do
    [
      core_cmd(
        "doc.get",
        "doc",
        "get",
        "Fetch one document by type and id.",
        "GET",
        "/v1/data/doc/:dataset/:type/:doc_id",
        "none",
        args: [
          arg("type", true, "string", "Document type (schema name)."),
          arg("doc_id", true, "string", "Document id.")
        ],
        flags: [
          flag(
            "perspective",
            "string",
            "published | drafts | raw. drafts prefers the drafts.<id> twin and falls back to the published row; published and raw resolve the id exactly as given. Any other value is a 400, never a silent downgrade to published.",
            default: "published"
          ),
          flag(
            "expand",
            "string",
            "Inline single reference fields (depth 1): a field name or comma list."
          ),
          flag(
            "fields",
            "string",
            "Return only these content fields (projection): a comma list. System fields (_id, _type, …) always included."
          )
        ],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.ls",
        "doc",
        "ls",
        "List documents of a type.",
        "GET",
        "/v1/data/query/:dataset/:type",
        "none",
        args: [arg("type", true, "string", "Document type to list.")],
        flags: [
          # default MUST match the server's real page size (QueryController.index:
          # parse_int(params["limit"], 100) — 100 since 8b81b12279, never 50). The
          # CLI calibrates its truncation warning from this field, so 50 made a
          # fully-returned 60-row page warn "more may be available".
          flag("limit", "int", "Max rows to return.", default: 100),
          flag("offset", "int", "Rows to skip.", default: 0),
          flag("all", "bool", "Fetch every page.", default: false),
          flag("perspective", "string", "published | drafts | raw.", default: "published"),
          flag(
            "expand",
            "string",
            "Inline single reference fields (depth 1): a field name or comma list."
          ),
          flag(
            "fields",
            "string",
            "Return only these content fields (projection): a comma list. System fields (_id, _type, …) always included."
          ),
          flag("order", "string", "Sort: <field>:asc|desc (e.g. title:asc, _updatedAt:desc)."),
          flag("count", "bool", "Add result.total (full match count) to the response.",
            default: false
          )
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.backlinks",
        "doc",
        "backlinks",
        "List the documents that reference this one (inbound references).",
        "GET",
        "/v1/data/backlinks/:dataset/:id",
        "read",
        args: [arg("id", true, "string", "Document id to find referrers of.")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      # auth_tier "read", NEVER "none" (D71): a none-tier read drops the bearer
      # and silently 404s private-schema reads to authenticated callers — the
      # proven doc.query bug class. The endpoint 404s anon (existence-hiding),
      # so it is read-tier like doc.backlinks.
      core_cmd(
        "doc.related",
        "doc",
        "related",
        "List documents related to this one: shared weighted tags fused with inbound references, best first.",
        "GET",
        "/v1/data/related/:dataset/:id",
        "read",
        args: [arg("id", true, "string", "Document id to find related documents for.")],
        flags: [flag("limit", "int", "Max related entries to return (default 10, max 50).")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      # Tag-registry reads (ae-w10). auth_tier "read", NEVER "none" — same D71
      # rationale as doc.related (both endpoints 404 anon, existence-hiding).
      core_cmd(
        "tag.browse",
        "tag",
        "browse",
        "Browse the tag registry: per-tag per-type published-document counts, biggest first.",
        "GET",
        "/v1/data/tags/:dataset",
        "read",
        flags: [
          flag("type", "string", "Comma list of document types to count (default paper,task).")
        ],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "tag.docs",
        "tag",
        "docs",
        "List the documents carrying a tag, ranked by that tag's strength — strongest first, legacy unweighted docs last.",
        "GET",
        "/v1/data/tags/:dataset/:tag",
        "read",
        args: [arg("tag", true, "string", "Tag name (exact match).")],
        flags: [
          flag("type", "string", "Comma list of document types to include (default paper,task).")
        ],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.history",
        "doc",
        "history",
        "List a document's revision history, newest first.",
        "GET",
        "/v1/data/history/:dataset/:type/:doc_id",
        "read",
        args: [
          arg("type", true, "string", "Document type."),
          arg("doc_id", true, "string", "Document id.")
        ],
        flags: [flag("limit", "int", "Max revisions to return.")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.revision",
        "doc",
        "revision",
        "Fetch one revision by id, with its content.",
        "GET",
        "/v1/data/revision/:dataset/:rev_id",
        "read",
        args: [arg("rev_id", true, "string", "Revision id (from doc history).")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.restore-revision",
        "doc",
        "restore-revision",
        "Restore a revision — writes its content back as a new draft.",
        "POST",
        "/v1/data/revision/:dataset/:rev_id/restore",
        "write",
        args: [
          arg("rev_id", true, "string", "Revision id to restore."),
          arg("type", true, "string", "Document type.")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "dataset.stats",
        "dataset",
        "stats",
        "Dataset content overview: total documents, per-type published/draft counts, and recent activity.",
        "GET",
        "/v1/data/analytics/:dataset",
        "read",
        writes: false,
        default_output: "json",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "data.counts",
        "data",
        "counts",
        "Bundled per-type published-document counts for a dataset in one query — {\"counts\":{\"<type>\":N,...}}.",
        "GET",
        "/v1/data/counts/:dataset",
        "read",
        writes: false,
        default_output: "json",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.query",
        "doc",
        "query",
        "Filtered read (GROQ-lite) over a type.",
        "GET",
        "/v1/data/query/:dataset/:type",
        "none",
        args: [arg("type", true, "string", "Document type to query.")],
        flags: [
          flag(
            "filter",
            "string",
            "field<op>value where op is = != > >= < <= ^= (starts) $= (ends) *= (contains) (e.g. status=published, slug^=2024-, title*=hello); or 'field in a,b,c' / 'field not in a,b,c'; or 'field is null' / 'field is not null'; or 'field hasStrong tag:min' (weighted-tag strength floor, e.g. tags hasStrong epic:50). Repeatable — every --filter is ANDed (two clauses on one field must use different operators). An unparseable filter is a 400 invalid_filter, never silently ignored.",
            repeatable: true
          ),
          flag(
            "fields",
            "string",
            "Return only these content fields (projection): a comma list. System fields (_id, _type, …) always included."
          ),
          # default MUST match the server's real page size (QueryController.index:
          # parse_int(params["limit"], 100) — 100 since 8b81b12279, never 50). The
          # CLI calibrates its truncation warning from this field, so 50 made a
          # fully-returned 60-row page warn "more may be available".
          flag("limit", "int", "Max rows to return.", default: 100),
          flag("offset", "int", "Rows to skip.", default: 0),
          flag("perspective", "string", "published | drafts | raw.", default: "published"),
          flag(
            "expand",
            "string",
            "Inline single reference fields (depth 1): a field name or comma list."
          ),
          flag("order", "string", "Sort: <field>:asc|desc (e.g. title:asc, _updatedAt:desc)."),
          flag("count", "bool", "Add result.total (full match count) to the response.",
            default: false
          )
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.mutate",
        "doc",
        "mutate",
        "Apply an atomic batch of mutations (create/patch/publish/unpublish/delete).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        flags: [
          flag("file", "file", "Mutations payload from a file or - for stdin."),
          flag("quiet", "bool", "Print only the resulting rev.", default: false)
        ],
        writes: true,
        batch: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.publish",
        "doc",
        "publish",
        "Publish a document's draft.",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [
          arg("type", true, "string", "Document type."),
          arg("id", true, "string", "Document id.")
        ],
        writes: true,
        mutation_op: "publish",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.unpublish",
        "doc",
        "unpublish",
        "Unpublish a document (move it back to draft).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [
          arg("type", true, "string", "Document type."),
          arg("id", true, "string", "Document id.")
        ],
        writes: true,
        mutation_op: "unpublish",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.discard-draft",
        "doc",
        "discard-draft",
        "Discard a document's draft edits (keep the published version).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [
          arg("type", true, "string", "Document type."),
          arg("id", true, "string", "Document id.")
        ],
        writes: true,
        mutation_op: "discardDraft",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.delete",
        "doc",
        "delete",
        "Delete a document.",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [
          arg("type", true, "string", "Document type."),
          arg("id", true, "string", "Document id.")
        ],
        writes: true,
        mutation_op: "delete",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.create",
        "doc",
        "create",
        "Create a document; fields via --set (id auto-generated unless --set _id=…).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [arg("type", true, "string", "Document type.")],
        flags: [
          flag("file", "file", "Document fields as a JSON object from a file or - for stdin."),
          flag("set", "string", "Field key=value (repeatable; key:=json for typed values).",
            repeatable: true
          )
        ],
        writes: true,
        mutation_op: "create",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.create-or-replace",
        "doc",
        "create-or-replace",
        "Create or replace a document by _id (upsert); fields via --set (must include --set _id=…).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [arg("type", true, "string", "Document type.")],
        flags: [
          flag("file", "file", "Document fields as a JSON object from a file or - for stdin."),
          flag(
            "set",
            "string",
            "Field key=value (repeatable; key:=json for typed). Must include _id.",
            repeatable: true
          )
        ],
        writes: true,
        mutation_op: "createOrReplace",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.create-if-not-exists",
        "doc",
        "create-if-not-exists",
        "Create a document by _id only if it does not exist (no-op otherwise); fields via --set (must include _id).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [arg("type", true, "string", "Document type.")],
        flags: [
          flag("file", "file", "Document fields as a JSON object from a file or - for stdin."),
          flag(
            "set",
            "string",
            "Field key=value (repeatable; key:=json for typed). Must include _id.",
            repeatable: true
          )
        ],
        writes: true,
        mutation_op: "createIfNotExists",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "doc.patch",
        "doc",
        "patch",
        "Patch a document: --set the fields to change (key:=json for typed values).",
        "POST",
        "/v1/data/mutate/:dataset",
        "write",
        args: [
          arg("type", true, "string", "Document type."),
          arg("id", true, "string", "Document id.")
        ],
        flags: [
          flag("set", "string", "Field key=value to change (repeatable; key:=json for typed).",
            repeatable: true
          )
        ],
        writes: true,
        mutation_op: "patch",
        set_key: "set",
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "schema.ls",
        "schema",
        "ls",
        "List all schema definitions in a dataset.",
        "GET",
        "/v1/schemas/:dataset",
        "admin",
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "schema.get",
        "schema",
        "get",
        "Fetch one schema definition.",
        "GET",
        "/v1/schemas/:dataset/:name",
        "admin",
        args: [arg("name", true, "string", "Schema name.")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "schema.apply",
        "schema",
        "apply",
        "Register or update a schema definition (upsert).",
        "POST",
        "/v1/schemas/:dataset",
        "admin",
        flags: [flag("file", "file", "Schema definition from a file or - for stdin.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "schema.delete",
        "schema",
        "delete",
        "Delete a content-type schema by name.",
        "DELETE",
        "/v1/schemas/:dataset/:name",
        "admin",
        args: [arg("name", true, "string", "Schema/type name to delete.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.ls",
        "media",
        "ls",
        "List media assets in a dataset.",
        "GET",
        "/v1/media/:dataset",
        "none",
        flags: [
          flag("limit", "int", "Max assets to return.", default: 50),
          flag("offset", "int", "Assets to skip.", default: 0)
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.upload",
        "media",
        "upload",
        "Upload a media asset.",
        "POST",
        "/v1/media/:dataset/upload",
        "write",
        args: [arg("file", true, "file", "File to upload.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.get",
        "media",
        "get",
        "Fetch a media asset's metadata by id.",
        "GET",
        "/v1/media/:dataset/:id",
        "none",
        args: [arg("id", true, "string", "Asset id.")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.delete",
        "media",
        "delete",
        "Delete a media asset by id.",
        "DELETE",
        "/v1/media/:dataset/:id",
        "write",
        args: [arg("id", true, "string", "Asset id.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.relations",
        "media",
        "relations",
        "Show an asset's relation graph — outbound refs + inbound where-used.",
        "GET",
        "/v1/media/:dataset/:id/relations",
        "none",
        args: [arg("id", true, "string", "Asset id.")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.checkout",
        "media",
        "checkout",
        "Check out an asset for editing (advisory lock). Member-only.",
        "POST",
        "/v1/media/:dataset/:id/checkout",
        "write",
        args: [arg("id", true, "string", "Asset id.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.undo-checkout",
        "media",
        "undo-checkout",
        "Release an asset's editorial lock. Member-only.",
        "POST",
        "/v1/media/:dataset/:id/undo-checkout",
        "write",
        args: [arg("id", true, "string", "Asset id.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.search",
        "media",
        "search",
        "Search the media library — full-text over metadata plus filters + facets.",
        "GET",
        "/v1/media/:dataset/search",
        "none",
        args: [
          arg("q", false, "string", "Search query (optional — omit for a filter-only browse).")
        ],
        flags: [
          flag("limit", "int", "Max hits to return.", default: 50),
          flag("offset", "int", "Hits to skip (paginate with --limit).", default: 0),
          flag("cursor", "string", "Keyset cursor from a prior result's nextCursor."),
          flag("type", "string", "Filter by MIME type (e.g. image/png)."),
          flag("kind", "string", "Filter by asset kind (image/video/…)."),
          flag("status", "string", "Filter by processing/lifecycle status."),
          flag("collection", "string", "Restrict to a collection id."),
          flag("tags", "string", "Comma-separated tag filter."),
          flag("sort", "string", "Sort order (default created-desc)."),
          flag("facets", "string", "Comma-separated facet dimensions to compute.")
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.suggest",
        "media",
        "suggest",
        "Typeahead suggestions for a media search box — recent/popular/nohits queries.",
        "GET",
        "/v1/media/:dataset/search/suggestions",
        "none",
        args: [
          arg("q", false, "string", "Partial query to filter suggestions (optional).")
        ],
        flags: [flag("limit", "int", "Max suggestions per bucket (default 8, max 20).")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.update",
        "media",
        "update",
        "Edit an asset's metadata: --set altText=… caption=… (key:=json for typed like tags).",
        "PATCH",
        "/v1/media/:dataset/:id",
        "write",
        args: [arg("id", true, "string", "Asset id.")],
        flags: [
          flag(
            "set",
            "string",
            "Metadata field key=value (repeatable; key:=json for typed values like tags/focalPoint).",
            repeatable: true
          )
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.collections",
        "media",
        "collections",
        "List media collections (folders / smart-folders).",
        "GET",
        "/v1/media/:dataset/collections",
        "none",
        flags: [
          flag("limit", "int", "Max collections to return.", default: 200),
          flag("offset", "int", "Collections to skip.", default: 0)
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.collection-assets",
        "media",
        "collection-assets",
        "List the assets in a media collection by id.",
        "GET",
        "/v1/media/:dataset/collections/:id/assets",
        "none",
        args: [arg("id", true, "string", "Collection id.")],
        flags: [
          flag("limit", "int", "Max assets to return.", default: 50),
          flag("offset", "int", "Assets to skip.", default: 0)
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.add-member",
        "media",
        "add-member",
        "Add an asset to a media collection.",
        "POST",
        "/v1/media/:dataset/collections/:id/members",
        "write",
        # The server's add_member reads `assetId` (camelCase) from the BODY, so the
        # arg name must be `assetId` to land there — NOT a path param like remove.
        args: [
          arg("id", true, "string", "Collection id."),
          arg("assetId", true, "string", "Asset id to add.")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.remove-member",
        "media",
        "remove-member",
        "Remove an asset from a media collection.",
        "DELETE",
        "/v1/media/:dataset/collections/:id/members/:asset_id",
        "write",
        # Mirror of the server's asymmetry: remove_member reads `:asset_id` from the
        # PATH (snake_case placeholder), unlike add-member's body `assetId`.
        args: [
          arg("id", true, "string", "Collection id."),
          arg("asset_id", true, "string", "Asset id to remove.")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.share-collection",
        "media",
        "share-collection",
        "Enable (or rotate) a public share link for a media collection.",
        "POST",
        "/v1/media/:dataset/collections/:id/share",
        "write",
        args: [arg("id", true, "string", "Collection id.")],
        # ttl rides query/body (Phoenix merges both into params["ttl"]).
        flags: [flag("ttl", "int", "Share-link lifetime in seconds (default 7 days).")],
        writes: true,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.revoke-share",
        "media",
        "revoke-share",
        "Revoke a media collection's public share link.",
        "DELETE",
        "/v1/media/:dataset/collections/:id/share",
        "write",
        args: [arg("id", true, "string", "Collection id.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      # ── media search-surface config + synonyms (task-b1801ed5c86d2e2e). Nine
      # routes under /v1/media/:dataset/search/* had zero commands — settings,
      # insights, synonyms (list/create/promote/preview/delete) and interaction
      # all rode the `media` noun with no verb at all. settings/insights/
      # synonyms sit behind `:flat_admin_api` (RequireAdmin) -> tier "admin",
      # matching the documents-search block below; search-interaction rides
      # bare `:api` -> "none", same as `media.suggest`/`media.search`.
      # `scoped_prefix` is set ONLY where router.ex actually mounts a
      # `/w/:workspace_slug/p/:project_slug` mirror — settings, synonym-preview
      # and promote have none.
      core_cmd(
        "media.search-settings",
        "media",
        "search-settings",
        "Read the media library's search-tuning config.",
        "GET",
        "/v1/media/:dataset/search/settings",
        "admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "media.update-search-settings",
        "media",
        "update-search-settings",
        "Update the media library's search-tuning config. --set key:=json for nested " <>
          "fields (searchableFields, typoPolicy, zeroHitStrategy, highlightFields); an " <>
          "omitted key keeps its current value.",
        "PUT",
        "/v1/media/:dataset/search/settings",
        "admin",
        flags: [
          flag(
            "set",
            "string",
            "Settings field key=value (repeatable; key:=json for typed values like " <>
              "highlightFields/searchableFields/typoPolicy).",
            repeatable: true
          )
        ],
        writes: true,
        default_output: "table"
      ),
      core_cmd(
        "media.search-insights",
        "media",
        "search-insights",
        "Search-quality analytics for the media library over a period: top queries, " <>
          "zero-hit rate, merge patterns.",
        "GET",
        "/v1/media/:dataset/search/insights",
        "admin",
        flags: [
          flag("period", "string", "day | week | month (default week)."),
          flag("periodStart", "string", "ISO date to anchor the period (default: current).")
        ],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.search-synonyms",
        "media",
        "search-synonyms",
        "List the media library's search synonyms.",
        "GET",
        "/v1/media/:dataset/search/synonyms",
        "admin",
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.search-synonym-preview",
        "media",
        "search-synonym-preview",
        "Preview a media search synonym's hit-count impact before creating it.",
        "GET",
        "/v1/media/:dataset/search/synonyms/preview",
        "admin",
        args: [arg("q", true, "string", "Query to preview an expansion for (aliases: from).")],
        flags: [
          flag("to", "string", "Target term — hit count for an alt_correction-style preview.")
        ],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "media.create-search-synonym",
        "media",
        "create-search-synonym",
        "Create a media search synonym (one_way: `from` also matches `to`; " <>
          "alt_correction: interchangeable).",
        "POST",
        "/v1/media/:dataset/search/synonyms",
        "admin",
        args: [
          arg("from", true, "string", "Source query term."),
          arg("to", true, "string", "Target query term.")
        ],
        flags: [
          flag("kind", "string", "one_way | alt_correction.", default: "one_way"),
          flag("source", "string", "manual | auto.", default: "manual"),
          flag("enabled", "bool", "Whether the synonym is active.", default: true)
        ],
        writes: true,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.promote-search-synonym",
        "media",
        "promote-search-synonym",
        "Promote a from/to pair straight to an auto-sourced media search synonym.",
        "POST",
        "/v1/media/:dataset/search/synonyms/promote",
        "admin",
        args: [
          arg("from", true, "string", "Source query term."),
          arg("to", true, "string", "Target query term.")
        ],
        flags: [flag("kind", "string", "one_way | alt_correction.", default: "one_way")],
        writes: true,
        default_output: "table"
      ),
      core_cmd(
        "media.delete-search-synonym",
        "media",
        "delete-search-synonym",
        "Delete a media search synonym by id.",
        "DELETE",
        "/v1/media/:dataset/search/synonyms/:id",
        "admin",
        args: [arg("id", true, "string", "Synonym id.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "media.search-interaction",
        "media",
        "search-interaction",
        "Record a click/select on a media search result, linked to its parent search event.",
        "POST",
        "/v1/media/:dataset/search/interaction",
        "none",
        args: [
          arg(
            "queryEventId",
            true,
            "string",
            "searchEventId from the media.search response this click belongs to."
          ),
          arg("objectId", true, "string", "Id of the asset the caller clicked/selected.")
        ],
        flags: [
          flag("type", "string", "select | click.", default: "click"),
          flag("position", "int", "0-based position of the result in the hit list.")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      # indx is a retriever ENGINE, not a Barkpark.Plugin (no plugin.json, absent
      # from registry.ex) — it is reached via the core `search` noun's --engine
      # flag (postgres|indx, default postgres), NOT as a plugin noun/verb.
      core_cmd(
        "search.query",
        "search",
        "query",
        "Full-text search documents in a dataset.",
        "GET",
        "/v1/data/search/:dataset",
        "none",
        args: [arg("q", true, "string", "Search query string.")],
        flags: [
          flag("engine", "string", "Search engine: postgres | indx.", default: "postgres"),
          flag("limit", "int", "Max hits to return.", default: 50),
          flag("offset", "int", "Hits to skip (paginate with --limit)."),
          flag("type", "string", "Restrict the search to one document type."),
          flag(
            "types",
            "string",
            "Restrict to several document types — a comma-separated allowlist (e.g. post,author)."
          ),
          flag(
            "fields",
            "string",
            "Project each hit's content to a comma-separated allowlist of field names " <>
              "(e.g. title,slug) — a token-thrifty response shape. Already honored by the " <>
              "controller; declared here so agents can discover it."
          ),
          flag("perspective", "string", "published (default) | drafts | raw.")
        ],
        paginated: true,
        writes: false,
        default_output: "table",
        # Supports the brief/full projection (R3): agents get token-thrifty hit
        # cards by default, humans get the full envelope. Emitted only under
        # ?views=1 (maybe_gate_views strips it otherwise).
        views: agent_views_descriptor(),
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      # ── search settings / synonyms / insights / suggestions / interaction /
      # correction / reindex (task-b1801ed5c86d2e2e). `search.query` above was
      # the ONLY command this whole /v1/data/search/:dataset family had —
      # twelve sibling routes rode the same noun with zero verbs. Tiers read
      # off each route's OWN pipeline (docs/cli/manifest.schema.json rule):
      # bare `[:api, :api_grant_read]` -> "none" (same as search.query),
      # `[:api, :require_token]` -> "read", `:flat_admin_api` (RequireAdmin)
      # -> "admin". `scoped_prefix` is set ONLY where router.ex actually
      # mounts a `/w/:workspace_slug/p/:project_slug` mirror — settings,
      # synonym-preview, promote and reindex have none.
      core_cmd(
        "search.suggestions",
        "search",
        "suggestions",
        "Typeahead suggestions for a document search box — recent/popular/nohits queries.",
        "GET",
        "/v1/data/search/:dataset/suggestions",
        "none",
        args: [
          arg("q", false, "string", "Partial query to filter suggestions (optional).")
        ],
        flags: [flag("limit", "int", "Max suggestions per bucket (default 8, max 20).")],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "search.interaction",
        "search",
        "interaction",
        "Record a click/select on a search result, linked to its parent search event.",
        "POST",
        "/v1/data/search/:dataset/interaction",
        "none",
        args: [
          arg(
            "queryEventId",
            true,
            "string",
            "searchEventId from the search.query response this click belongs to."
          ),
          arg("objectId", true, "string", "Id of the document the caller clicked/selected.")
        ],
        flags: [
          flag("type", "string", "select | click.", default: "click"),
          flag("position", "int", "0-based position of the result in the hit list.")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "search.correction",
        "search",
        "correction",
        "Record a query-correction signal (from -> to); auto-promotes to a synonym " <>
          "after two distinct sessions.",
        "POST",
        "/v1/data/search/:dataset/correction",
        "none",
        args: [
          arg("from", true, "string", "The query the caller actually typed."),
          arg("to", true, "string", "The query the caller meant / corrected to.")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "search.reindex",
        "search",
        "reindex",
        "Enqueue an Indx blue/green rebuild for a dataset.",
        "POST",
        "/v1/data/search/:dataset/reindex",
        # `[:api, :require_token]` — any member token, not admin-only (see the
        # route's own comment in router.ex on why this stays `read`).
        "read",
        flags: [
          flag(
            "types",
            "string",
            "Comma-separated document types to reindex (default: every core type)."
          )
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "search.settings",
        "search",
        "settings",
        "Read a dataset's search-tuning config (searchable fields, typo policy, " <>
          "zero-hit strategy).",
        "GET",
        "/v1/data/search/:dataset/settings",
        "admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "search.update-settings",
        "search",
        "update-settings",
        "Update a dataset's search-tuning config. --set key:=json for nested fields " <>
          "(searchableFields, typoPolicy, zeroHitStrategy, highlightFields); an omitted " <>
          "key keeps its current value.",
        "PUT",
        "/v1/data/search/:dataset/settings",
        "admin",
        flags: [
          flag(
            "set",
            "string",
            "Settings field key=value (repeatable; key:=json for typed values like " <>
              "highlightFields/searchableFields/typoPolicy).",
            repeatable: true
          )
        ],
        writes: true,
        default_output: "table"
      ),
      core_cmd(
        "search.insights",
        "search",
        "insights",
        "Search-quality analytics for a dataset over a period: top queries, zero-hit " <>
          "rate, merge patterns.",
        "GET",
        "/v1/data/search/:dataset/insights",
        "admin",
        flags: [
          flag("period", "string", "day | week | month (default week)."),
          flag("periodStart", "string", "ISO date to anchor the period (default: current).")
        ],
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "search.synonyms",
        "search",
        "synonyms",
        "List a dataset's search synonyms.",
        "GET",
        "/v1/data/search/:dataset/synonyms",
        "admin",
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "search.synonym-preview",
        "search",
        "synonym-preview",
        "Preview a synonym's hit-count impact before creating it.",
        "GET",
        "/v1/data/search/:dataset/synonyms/preview",
        "admin",
        args: [arg("q", true, "string", "Query to preview an expansion for (aliases: from).")],
        flags: [
          flag("to", "string", "Target term — hit count for an alt_correction-style preview.")
        ],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "search.create-synonym",
        "search",
        "create-synonym",
        "Create a search synonym (one_way: `from` also matches `to`; alt_correction: " <>
          "interchangeable).",
        "POST",
        "/v1/data/search/:dataset/synonyms",
        "admin",
        args: [
          arg("from", true, "string", "Source query term."),
          arg("to", true, "string", "Target query term.")
        ],
        flags: [
          flag("kind", "string", "one_way | alt_correction.", default: "one_way"),
          flag("source", "string", "manual | auto.", default: "manual"),
          flag("enabled", "bool", "Whether the synonym is active.", default: true)
        ],
        writes: true,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "search.promote-synonym",
        "search",
        "promote-synonym",
        "Promote a from/to pair straight to an auto-sourced synonym (the same path " <>
          "record_correction takes after two distinct sessions).",
        "POST",
        "/v1/data/search/:dataset/synonyms/promote",
        "admin",
        args: [
          arg("from", true, "string", "Source query term."),
          arg("to", true, "string", "Target query term.")
        ],
        flags: [flag("kind", "string", "one_way | alt_correction.", default: "one_way")],
        writes: true,
        default_output: "table"
      ),
      core_cmd(
        "search.delete-synonym",
        "search",
        "delete-synonym",
        "Delete a search synonym by id.",
        "DELETE",
        "/v1/data/search/:dataset/synonyms/:id",
        "admin",
        args: [arg("id", true, "string", "Synonym id.")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "workspace.ls",
        "workspace",
        "ls",
        "List workspaces the token can reach.",
        "GET",
        "/api/workspaces",
        "read",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "workspace.create",
        "workspace",
        "create",
        "Create a new workspace owned by the caller (+ Default project + production dataset).",
        "POST",
        "/api/workspaces",
        # Route fact: POST /api/workspaces sits behind `[:api, :require_token]`
        # (RequireToken only — NO :require_write). Any authenticated token,
        # including a read-only one, may self-serve a workspace (it becomes the
        # owner-member). The manifest tier must mirror that floor: `read`, not
        # `write` — else existence-hiding wrongly strips the verb from a
        # read-tier caller who can actually invoke it.
        "read",
        args: [arg("name", true, "string", "Workspace name (slug derived when omitted).")],
        flags: [flag("slug", "string", "Explicit slug (derived from name when absent).")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "workspace.project-create",
        "workspace",
        "project-create",
        "Create a project under a workspace (project verbs fold under workspace).",
        "POST",
        "/api/workspaces/:workspace_slug/projects",
        "scoped_admin",
        args: [arg("name", true, "string", "Project name.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "workspace.project-ls",
        "workspace",
        "project-ls",
        "List projects under a workspace (the active --workspace).",
        "GET",
        "/api/workspaces/:workspace_slug/projects",
        "read",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "workspace.dataset-ls",
        "workspace",
        "dataset-ls",
        "List datasets under a project (the active --workspace + --project).",
        "GET",
        "/api/workspaces/:workspace_slug/projects/:project_slug/datasets",
        "read",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "workspace.member-ls",
        "workspace",
        "member-ls",
        "The workspace roster — every seat (humans AND api tokens) with its role.",
        "GET",
        "/v1/members",
        "scoped_admin",
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "workspace.member-add",
        "workspace",
        "member-add",
        "Seat a human in the workspace by e-mail (creates the account if new; sends no mail).",
        "POST",
        "/v1/members",
        "scoped_admin",
        args: [arg("email", true, "string", "E-mail of the person to seat.")],
        flags: [
          flag("role", "string", "owner | admin | member (or a custom role).", default: "member")
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "workspace.member-role",
        "workspace",
        "member-role",
        "Change a seat's role. Refuses to demote the workspace's last owner.",
        "PATCH",
        "/v1/members/:principal_ref",
        "scoped_admin",
        args: [
          arg("principal_ref", true, "string", "E-mail, or a principal id."),
          arg("role", true, "string", "owner | admin | member (or a custom role).")
        ],
        flags: [
          flag("principal_type", "string", "Kind of a RAW id — user | api_token.",
            default: "user"
          )
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "workspace.member-rm",
        "workspace",
        "member-rm",
        "Remove a seat (does not revoke a token — see token revoke). Refuses the last owner.",
        "DELETE",
        "/v1/members/:principal_ref",
        "scoped_admin",
        args: [arg("principal_ref", true, "string", "E-mail, or a principal id.")],
        flags: [
          flag("principal_type", "string", "Kind of a RAW id — user | api_token.",
            default: "user"
          )
        ],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "token.ls",
        "token",
        "ls",
        "The token inventory for this workspace — label, permissions, revoked/expiry state.",
        "GET",
        "/v1/tokens",
        "scoped_admin",
        writes: false,
        default_output: "table",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "token.revoke",
        "token",
        "revoke",
        "Revoke a token that holds a seat in this workspace (idempotent, audited).",
        "DELETE",
        "/v1/tokens/:id",
        "scoped_admin",
        args: [arg("id", true, "string", "Token id (from token ls).")],
        writes: true,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "token.create",
        "token",
        "create",
        "Mint a read-only, workspace-bound API token (public-read/read only).",
        "POST",
        "/v1/tokens",
        "scoped_admin",
        args: [arg("label", true, "string", "Human label for the minted token.")],
        flags: [
          flag(
            "permissions",
            "string",
            "Comma list — public-read|read ONLY (default public-read).",
            default: "public-read"
          ),
          flag("dataset", "string", "Dataset to bind.", default: "production")
        ],
        writes: true,
        default_output: "json",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      ),
      core_cmd(
        "webhook.ls",
        "webhook",
        "ls",
        "List webhook subscriptions.",
        "GET",
        "/v1/webhooks/:dataset",
        "admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "webhook.create",
        "webhook",
        "create",
        "Create a webhook subscription.",
        "POST",
        "/v1/webhooks/:dataset",
        # admin — the /v1/webhooks route block is pipe_through [:api, :require_admin];
        # a "write" tier offered this to write tokens the server then 403s.
        "admin",
        args: [arg("url", true, "string", "Delivery URL.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "webhook.get",
        "webhook",
        "get",
        "Fetch a webhook subscription by id.",
        "GET",
        "/v1/webhooks/:dataset/:id",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "webhook.delete",
        "webhook",
        "delete",
        "Delete a webhook subscription by id.",
        "DELETE",
        "/v1/webhooks/:dataset/:id",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "webhook.update",
        "webhook",
        "update",
        "Update a webhook subscription's delivery URL.",
        "PUT",
        "/v1/webhooks/:dataset/:id",
        "admin",
        args: [
          arg("id", true, "string", "Webhook id."),
          arg("url", true, "string", "New delivery URL.")
        ],
        writes: true,
        default_output: "minimal"
      ),
      # ── C5 operator-console webhook surface (delivery log / replay / rotate) ──
      # These three land the C5 routes into the manifest so `bp` and the cloud
      # SPA drive them through the same contract as the CRUD verbs above. All
      # admin-tier (the /v1/webhooks block is pipe_through [:api, :require_admin]).
      core_cmd(
        "webhook.deliveries",
        "webhook",
        "deliveries",
        "List an endpoint's recent deliveries (newest-first, with latency).",
        "GET",
        "/v1/webhooks/:dataset/:id/deliveries",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "webhook.replay",
        "webhook",
        "replay",
        "Replay a stored event to this webhook as a fresh delivery attempt.",
        "POST",
        "/v1/webhooks/:dataset/:id/deliveries/:event_id/replay",
        "admin",
        args: [
          arg("id", true, "string", "Webhook id."),
          arg("event_id", true, "string", "Mutation event id to replay.")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "webhook.rotate",
        "webhook",
        "rotate",
        "Rotate the endpoint's signing secret (returns the new secret once).",
        "POST",
        "/v1/webhooks/:dataset/:id/rotate",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "webhook.reenable",
        "webhook",
        "reenable",
        "Reenable a webhook endpoint after it was auto-disabled.",
        "POST",
        "/v1/webhooks/:dataset/:id/reenable",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "webhook.test-send",
        "webhook",
        "test-send",
        "Send a one-shot synthetic test event to this endpoint (single attempt).",
        "POST",
        "/v1/webhooks/:dataset/:id/test-send",
        "admin",
        args: [arg("id", true, "string", "Webhook id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "plugin.ls",
        "plugin",
        "ls",
        "List installed plugins.",
        "GET",
        "/v1/plugins",
        "admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "plugin.settings",
        "plugin",
        "settings",
        "Read or update a plugin's settings.",
        "PUT",
        "/v1/plugins/settings/:plugin_name",
        "admin",
        args: [arg("plugin_name", true, "string", "Plugin name.")],
        flags: [flag("set", "string", "key=value setting to apply.", repeatable: true)],
        writes: true,
        default_output: "minimal"
      ),
      # ── Cloud run-secrets (admin-only encrypted store) ───────────────────
      # All four sit behind /v1/secrets [:api, :require_admin]. secret.get
      # REVEALS the unmasked value (audited); secret.ls stays masked.
      core_cmd(
        "secret.ls",
        "secret",
        "ls",
        "List run-secret names with masked values (newest write first).",
        "GET",
        "/v1/secrets",
        "admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "secret.get",
        "secret",
        "get",
        "Reveal a run-secret's unmasked value (writes a reveal audit row).",
        "GET",
        "/v1/secrets/:name",
        "admin",
        args: [arg("name", true, "string", "Secret name.")],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "secret.set",
        "secret",
        "set",
        "Set or rotate a run-secret value.",
        "PUT",
        "/v1/secrets/:name",
        "admin",
        args: [
          arg("name", true, "string", "Secret name."),
          arg("value", true, "string", "Secret value to store (encrypted at rest).")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "secret.rm",
        "secret",
        "rm",
        "Delete a run-secret by name.",
        "DELETE",
        "/v1/secrets/:name",
        "admin",
        args: [arg("name", true, "string", "Secret name.")],
        writes: true,
        default_output: "minimal"
      ),
      # ── Scoped run-secrets — the per-WORKSPACE tier (connectors D200) ────
      # Four DEDICATED verbs with the workspace/project slugs BAKED into
      # path_template (the workspace.project-create precedent) — deliberately
      # NOT the scoped_prefix mechanism: ctx.ScopedMirror is never set in any
      # production Go path, so a flat template + scoped_prefix emits the flat
      # URL and 404s (proven live on token.create — bp-token-create-
      # scoped-prefix-404 / #3197; NOT fixed here, its pattern is banned).
      # auth_tier scoped_admin = per-workspace OWNER/ADMIN role
      # (RequireWorkspaceRole). The flat secret.* verbs above stay the
      # instance-GLOBAL tier, untouched.
      core_cmd(
        "secret.scoped-ls",
        "secret",
        "scoped-ls",
        "List a workspace's scoped run-secret names with masked values.",
        "GET",
        "/w/:workspace_slug/p/:project_slug/v1/secrets",
        "scoped_admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "secret.scoped-get",
        "secret",
        "scoped-get",
        "Reveal a workspace-scoped run-secret's unmasked value (audited).",
        "GET",
        "/w/:workspace_slug/p/:project_slug/v1/secrets/:name",
        "scoped_admin",
        args: [arg("name", true, "string", "Secret name.")],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "secret.scoped-set",
        "secret",
        "scoped-set",
        "Set or rotate a workspace-scoped run-secret value.",
        "PUT",
        "/w/:workspace_slug/p/:project_slug/v1/secrets/:name",
        "scoped_admin",
        args: [
          arg("name", true, "string", "Secret name."),
          arg("value", true, "string", "Secret value to store (encrypted at rest).")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "secret.scoped-rm",
        "secret",
        "scoped-rm",
        "Delete a workspace-scoped run-secret by name.",
        "DELETE",
        "/w/:workspace_slug/p/:project_slug/v1/secrets/:name",
        "scoped_admin",
        args: [arg("name", true, "string", "Secret name.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "share.ls",
        "share",
        "ls",
        "List scoped network shares (env baseline + persisted).",
        "GET",
        "/v1/shares",
        "admin",
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "share.add",
        "share",
        "add",
        "Expose a scope's surface on the LAN (upsert a persisted share).",
        "POST",
        "/v1/shares",
        "admin",
        args: [
          arg(
            "scope",
            true,
            "string",
            "ws[/project[/dataset]] — defaults project=default, dataset=production."
          ),
          arg("surfaces", true, "string", "Comma list: papers,docs,media.")
        ],
        flags: [flag("access", "string", "read | edit.", default: "read")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "share.rm",
        "share",
        "rm",
        "Remove a persisted share by scope (env shares are unaffected).",
        "DELETE",
        "/v1/shares",
        "admin",
        args: [arg("scope", true, "string", "ws[/project[/dataset]] to stop sharing.")],
        writes: true,
        default_output: "minimal"
      ),
      # ── P5 edit-token management + P7 item share links (task
      # wb-api-capabilities-undeclared-verbs) ─────────────────────────────
      # Six routes under the SAME /v1/shares scope as share.ls/add/rm above,
      # mounted behind the identical [:api, :require_admin] pipeline — kept at
      # the same `admin` global tier as their siblings even though the
      # controller additionally confines mint/list/revoke to a workspace admin
      # of the TARGET row (ShareController / ShareLinkController moduledocs);
      # that extra object-level check is not a different global tier, exactly
      # as share.add/rm's own workspace_admin?/2 confinement does not move
      # them off `admin` either.
      core_cmd(
        "share.token-ls",
        "share",
        "token-ls",
        "List share edit-tokens (optional scope filter), confined to workspaces the caller admins.",
        "GET",
        "/v1/shares/tokens",
        "admin",
        flags: [flag("scope", "string", "Filter by ws[/project[/dataset]] scope.")],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "share.token-mint",
        "share",
        "token-mint",
        "Mint a share edit-token for one scope's surfaces (raw token shown once).",
        "POST",
        "/v1/shares/tokens",
        "admin",
        args: [
          arg(
            "scope",
            true,
            "string",
            "ws[/project[/dataset]] — defaults project=default, dataset=production."
          ),
          arg("surfaces", true, "string", "Comma list: docs,media.")
        ],
        flags: [
          flag("access", "string", "read | edit.", default: "read"),
          flag("ttl", "int", "Token TTL in seconds."),
          flag("label", "string", "Human label for the minted token.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "share.token-revoke",
        "share",
        "token-revoke",
        "Revoke a share edit-token by id.",
        "DELETE",
        "/v1/shares/tokens/:token_id",
        "admin",
        args: [arg("token_id", true, "string", "Share edit-token id (from share token-ls).")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "share.link-ls",
        "share",
        "link-ls",
        "List the item share-links (P7) for one doc/media item.",
        "GET",
        "/v1/shares/links",
        "admin",
        args: [
          arg("scope", true, "string", "ws[/project[/dataset]] the item lives in."),
          arg("kind", true, "string", "doc | media."),
          arg("ref_id", true, "string", "The item's id.")
        ],
        flags: [flag("ref_type", "string", "Document type — required when kind=doc.")],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "share.link-mint",
        "share",
        "link-mint",
        "Mint a direct share link (P7) to ONE doc/media item (raw token shown once).",
        "POST",
        "/v1/shares/links",
        "admin",
        args: [
          arg("scope", true, "string", "ws[/project[/dataset]] the item lives in."),
          arg("kind", true, "string", "doc | media."),
          arg("ref_id", true, "string", "The item's id.")
        ],
        flags: [
          flag("ref_type", "string", "Document type — required when kind=doc."),
          flag("access", "string", "read | edit.", default: "read"),
          flag("label", "string", "Human label for the minted link."),
          flag("ttl", "int", "Link TTL in seconds.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "share.link-revoke",
        "share",
        "link-revoke",
        "Revoke one item share-link by id.",
        "DELETE",
        "/v1/shares/links/:id",
        "admin",
        args: [arg("id", true, "string", "Share link id (from share link-ls).")],
        writes: true,
        default_output: "minimal"
      ),
      # ── Content graph (Goal ges/graph-edge-seam) ─────────────────────────
      # Mounted from CORE so the verbs survive the `:plugins, []` kill switch
      # (the graph roots on ANY content doc). All `auth_tier: "read"`: the
      # /v1/graph/* routes sit behind the `[:api, :require_token]` pipeline —
      # bearer-gated, NOT admin. No scoped_prefix — these are global
      # content-graph reads, not scoped to a single doc prefix.
      core_cmd(
        "graph.show",
        "graph",
        "show",
        "Traverse the content graph from a root document (any type).",
        "GET",
        "/v1/graph/:id",
        "read",
        args: [arg("id", true, "string", "Root document id.")],
        flags: [
          flag("depth", "int", "Traversal depth (clamped 1..5).", default: 2),
          flag("direction", "string", "out | in | both (default both)."),
          flag("kinds", "string", "Comma-separated edge kinds to keep."),
          flag("sources", "string", "Comma-separated plugin_source filters."),
          flag(
            "perspective",
            "string",
            "published (default) | drafts (live extract over the drafts corpus)."
          )
        ],
        writes: false,
        default_output: "json"
      ),
      # Expectation reverse view (lvw-t8, living-values §8/§9): the tasks a
      # paper drives — its design_doc/papers referencers — with per-criterion
      # met/evidence state. Read-side; published corpus; node-budget bounded.
      core_cmd(
        "graph.tasks",
        "graph",
        "tasks",
        "Tasks that cite a document (a paper's driven tasks) with their acceptance-criteria expectation state.",
        "GET",
        "/v1/graph/:id/tasks",
        "read",
        args: [arg("id", true, "string", "Document id the tasks cite (typically a paper slug).")],
        flags: [flag("dataset", "string", "Dataset to scope to (default production).")],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "graph.orphans",
        "graph",
        "orphans",
        "List documents with zero inbound and zero outbound edges.",
        "GET",
        "/v1/graph/orphans",
        "read",
        flags: [flag("dataset", "string", "Dataset to scope to (default production).")],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "graph.dangling",
        "graph",
        "dangling",
        "List broken references (targets unresolvable under the published lens).",
        "GET",
        "/v1/graph/dangling",
        "read",
        flags: [flag("dataset", "string", "Dataset to scope to (default production).")],
        writes: false,
        default_output: "json"
      ),
      # ── Core user auth (login/sessions/MFA/email flows) ──────────────────
      # Pre-tenant, global (no scoped_prefix). The 5 public verbs are tier
      # "none" so an anon caller can discover login; the 5 session-gated verbs
      # are tier "read" (hidden from anon, shown to any authenticated caller).
      # `writes: true` for all of them (PDS-D302): `writes` means "has side
      # effects", not "mutates a document" — these exchanges mint sessions,
      # rotate passwords and disable MFA. They used to omit the flag and so
      # rode the `false` default, which `internal/cli/mcp_bridge.go` turns into
      # `ReadOnlyHint: true` — an MCP client was told `auth.mfa-disable` was a
      # safe read-only call. bp's content --dry-run/confirm path keys off the
      # content mutation verbs, not off this bit.
      # Paths mirror the `scope "/v1/auth"` blocks in router.ex (public entry +
      # session-gated).
      core_cmd(
        "auth.register",
        "auth",
        "register",
        "Register a new user account (email + password).",
        "POST",
        "/v1/auth/register",
        "none",
        args: [
          arg("email", true, "string", "Account email address."),
          arg("password", true, "string", "Account password.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.login",
        "auth",
        "login",
        "Log in and mint a user session token.",
        "POST",
        "/v1/auth/login",
        "none",
        args: [
          arg("email", true, "string", "Account email address."),
          arg("password", true, "string", "Account password.")
        ],
        flags: [
          flag("totp_code", "string", "Six-digit TOTP code (when MFA is enrolled)."),
          flag("recovery_code", "string", "One-time MFA recovery code (TOTP fallback).")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.verify-email",
        "auth",
        "verify-email",
        "Confirm an email address with a verification token.",
        "POST",
        "/v1/auth/verify-email",
        "none",
        args: [arg("token", true, "string", "Email verification token.")],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.request-reset",
        "auth",
        "request-reset",
        "Request a password-reset token by email.",
        "POST",
        "/v1/auth/request-reset",
        "none",
        args: [arg("email", true, "string", "Account email address.")],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.reset",
        "auth",
        "reset",
        "Reset a password using a reset token.",
        "POST",
        "/v1/auth/reset",
        "none",
        args: [
          arg("token", true, "string", "Password-reset token."),
          arg("password", true, "string", "New password.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.me",
        "auth",
        "me",
        "Return the current user's account for the active session.",
        "GET",
        "/v1/auth/me",
        "read",
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "auth.logout",
        "auth",
        "logout",
        "Revoke the active user session.",
        "DELETE",
        "/v1/auth/logout",
        "read",
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.mfa-enroll",
        "auth",
        "mfa-enroll",
        "Begin TOTP MFA enrolment (returns a secret to confirm).",
        "POST",
        "/v1/auth/mfa/enroll",
        "read",
        # The server re-auths (MEDIUM-8) — enrol/verify/disable all require the
        # account password in the body, not just a session token. Without it the
        # endpoint 422s "password required".
        args: [arg("password", true, "string", "Account password (re-auth).")],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.mfa-verify",
        "auth",
        "mfa-verify",
        "Confirm TOTP MFA enrolment with a secret + code.",
        "POST",
        "/v1/auth/mfa/verify",
        "read",
        args: [
          arg("secret", true, "string", "TOTP secret from enrolment."),
          arg("code", true, "string", "Six-digit TOTP code."),
          arg("password", true, "string", "Account password (re-auth).")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "auth.mfa-disable",
        "auth",
        "mfa-disable",
        "Disable TOTP MFA on the account.",
        "POST",
        "/v1/auth/mfa/disable",
        "read",
        args: [arg("password", true, "string", "Account password (re-auth).")],
        writes: true,
        default_output: "json"
      ),
      # ── Airdrop grants — the `access` noun (grantor surface) ──────────────
      # CORE (survives `:plugins, []`). All four sit behind `[:api,
      # :require_token]` at root `/v1/access` — the workspace comes from the
      # body (grant) / query (ls) / the grant itself (show/revoke), NOT a path
      # slug, so there is NO scoped_prefix. mint/revoke authorize per-workspace
      # INSIDE Barkpark.Access (no-escalation on mint, grantor-or-admin on
      # revoke) → `scoped_admin` tier: visible to any authenticated token, the
      # server decides the per-workspace authority. ls/show are bearer reads.
      #
      # The grantee CLAIM/MINE verbs (`access claim` / `access mine`) DO ship
      # now (ag-bp-user-identity-auth): an api_token can carry a USER identity
      # via `owner_user_id`, and the `:access_principal` pipeline resolves an
      # OWNED token → `:current_user`, so `POST /v1/access/claim` +
      # `GET /v1/access/mine` work from a terminal holding an owned token. Tier
      # `read` — an authenticated (owned) token is required; anon is hidden. A
      # NULL-owner token still fails closed (401) at the pipeline.
      core_cmd(
        "access.grant",
        "access",
        "grant",
        "Mint an airdrop grant — a time-boxed, account-bound scoped access link.",
        "POST",
        "/v1/access",
        "scoped_admin",
        args: [
          arg(
            "grantee_email",
            true,
            "string",
            "Who the link is FOR (claimed by a matching account)."
          ),
          arg("workspace_id", true, "string", "Workspace scope top (required)."),
          arg(
            "capabilities",
            true,
            "string",
            "Comma list — read|write|admin (only what you hold)."
          )
        ],
        flags: [
          flag("project_id", "string", "Narrow the scope to a project."),
          flag("dataset", "string", "Narrow the scope to a dataset."),
          flag("type", "string", "Narrow the scope to a document type."),
          flag("doc_id", "string", "Narrow the scope to a single document."),
          flag("single_use", "boolean", "Spend the grant on its first claim."),
          flag("expires_at", "string", "ISO-8601 expiry instant.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "access.ls",
        "access",
        "ls",
        "List active airdrop grants for a workspace (grantor-scoped).",
        "GET",
        "/v1/access",
        "read",
        flags: [flag("workspace_id", "string", "Workspace whose grants to list (required).")],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "access.show",
        "access",
        "show",
        "Show one airdrop grant by id (grantor or workspace admin).",
        "GET",
        "/v1/access/:id",
        "read",
        args: [arg("id", true, "string", "Grant id.")],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "access.revoke",
        "access",
        "revoke",
        "Revoke an airdrop grant by id (idempotent; grantor or admin).",
        "DELETE",
        "/v1/access/:id",
        "scoped_admin",
        args: [arg("id", true, "string", "Grant id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "access.claim",
        "access",
        "claim",
        "Claim an airdrop grant addressed to your account (requires an owned token or a login session).",
        "POST",
        "/v1/access/claim",
        "read",
        args: [arg("token", true, "string", "The raw airdrop link token to claim.")],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "access.mine",
        "access",
        "mine",
        "List the active airdrop grants bound to your account.",
        "GET",
        "/v1/access/mine",
        "read",
        writes: false,
        default_output: "table"
      ),
      # ── Profile-driven Epic / Legendary cycle ledger ───────────────────
      # These commands name the canonical project-scoped route directly. Flat
      # /v1/cycles routes remain a projectless compatibility API and are never
      # selected by bp through the deferred ScopedMirror seam.
      core_cmd(
        "cycle.show",
        "cycle",
        "show",
        "Read the canonical CycleFleet reconciliation and projected fleet.",
        "GET",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id",
        "read",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Wave id.")
        ],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "cycle.open",
        "cycle",
        "open",
        "Freeze a cycle profile, inventory, and experiment contract before fan-out.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/open",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Wave id."),
          arg(
            "profile",
            false,
            "string",
            "Standard open only: epic | legendary. Omit when opening a correction wave."
          ),
          arg(
            "inventory_json",
            false,
            "string",
            "Standard open only: JSON array of immutable inventory units. Omit for corrections."
          ),
          arg(
            "scale_contract_json",
            false,
            "string",
            "Standard open only: complete Legendary scale contract JSON; use {} for profile=epic."
          )
        ],
        flags: [
          flag(
            "experiment_contract_json",
            "string",
            "Optional JSON experiment contract; Legendary accepts the canonical five-round contract."
          ),
          flag(
            "correction_of_json",
            "string",
            "Correction open only: canonical correction_of-v1 JSON naming the prior wave and exact false claims."
          ),
          flag(
            "correction_of_digest",
            "string",
            "Correction open only: SHA-256 digest of the canonical correction_of-v1 JSON."
          ),
          flag(
            "release_gate_receipt_json",
            "string",
            "Correction open only: exact admitted cycle-release-gate-v1 open receipt."
          )
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.release-gate-open",
        "cycle",
        "release-gate-open",
        "Admit and reserve the immutable pre-open contract for one correction.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/open",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Prospective correction wave id."),
          arg("idempotency_key", true, "string", "Stable admission replay key."),
          arg("correction_of_json", true, "string", "Canonical correction_of-v1 JSON."),
          arg("correction_of_digest", true, "string", "Canonical correction digest.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.release-paper-stage",
        "cycle",
        "release-paper-stage",
        "Stage one immutable campaign or successor Paper candidate for an admitted release gate.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/papers/:role/stage",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Prospective correction wave id."),
          arg("release_gate_id", true, "string", "Admitted release gate UUID."),
          arg("role", true, "string", "campaign | successor"),
          arg("document_id", true, "string", "Stable Paper document id."),
          arg("title", true, "string", "Paper title."),
          arg("content_json", true, "string", "Canonical Paper content JSON object.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.release-gate-activate",
        "cycle",
        "release-gate-activate",
        "Capture every required reader and activate one fully staged release gate.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/release-gates/:release_gate_id/activate",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Prospective correction wave id."),
          arg("release_gate_id", true, "string", "Fully staged release gate UUID."),
          arg("idempotency_key", true, "string", "Stable activation replay key."),
          arg("b1_experiment_id", true, "string", "Exact accepted B1 experiment identifier.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.seal",
        "cycle",
        "seal",
        "Seal post-pilot capacity evidence and the resulting immutable build plan.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/seal",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Wave id."),
          arg("proven_batch_capacity", true, "int", "Units proven safe per builder."),
          arg("chosen_format", true, "string", "Pilot-selected build format."),
          arg("pilot_evidence", true, "string", "Evidence URI or durable reference."),
          arg("pilot_evidence_revision", true, "string", "Evidence revision."),
          arg("failure_rate", true, "string", "Observed pilot failure rate."),
          arg("failure_threshold", true, "string", "Maximum accepted failure rate."),
          arg(
            "golden_fixtures_json",
            true,
            "string",
            "JSON array of frozen golden fixture references."
          )
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.assign",
        "cycle",
        "assign",
        "Append one immutable typed assignment snapshot to a cycle wave.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/assignments",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Wave id."),
          arg("assignment_id", true, "string", "Logical idempotent assignment id."),
          arg("phase", true, "string", "survey | verify | experiment | build | review"),
          arg("agent_type", true, "string", "Contract agent type."),
          arg("effort", true, "string", "Reasoning effort."),
          arg("snapshot_json", true, "string", "JSON assignment snapshot and owned units.")
        ],
        flags: [
          flag(
            "task_id",
            "string",
            "Physical same-project Task row id frozen with this assignment."
          ),
          flag(
            "replaces_assignment_id",
            "string",
            "Logical assignment id replaced by this retry."
          )
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.result",
        "cycle",
        "result",
        "Append or idempotently replay one typed terminal assignment result.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/assignments/:assignment_id/results",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Wave id."),
          arg("assignment_id", true, "string", "Logical assignment id."),
          arg("idempotency_key", true, "string", "Stable result replay key."),
          arg("status", true, "string", "completed | failed"),
          arg("summary", true, "string", "Terminal summary."),
          arg("evidence", true, "string", "Evidence URI or durable reference."),
          arg("evidence_revision", true, "string", "Evidence revision."),
          arg("payload_json", true, "string", "JSON typed result payload.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.quarantine",
        "cycle",
        "quarantine",
        "Append immutable evidence that a correction wave cannot be promoted.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/quarantine",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Ancestry-root wave id."),
          arg("idempotency_key", true, "string", "Stable quarantine replay key."),
          arg("reason", true, "string", "Durable quarantine reason."),
          arg("correction_receipt_json", true, "string", "Canonical correction receipt JSON."),
          arg("evidence", true, "string", "Evidence URI or durable reference."),
          arg("evidence_revision", true, "string", "Evidence revision.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.promote",
        "cycle",
        "promote",
        "Append a fenced event making one verified correction current.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/promote",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Ancestry-root wave id."),
          arg("idempotency_key", true, "string", "Stable promotion replay key."),
          arg("correction_receipt_json", true, "string", "Canonical correction receipt JSON."),
          arg("gate_receipt_json", true, "string", "Canonical release-gate receipt JSON."),
          arg("evidence", true, "string", "Evidence URI or durable reference."),
          arg("evidence_revision", true, "string", "Evidence revision.")
        ],
        flags: [
          flag(
            "previous_event_id",
            "string",
            "Current promotion event UUID; omit only for the first promotion."
          )
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "cycle.rollback",
        "cycle",
        "rollback",
        "Append a fenced pointer event restoring an earlier verified correction.",
        "POST",
        "/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id/rollback",
        "write",
        args: [
          arg("epic_id", true, "string", "Epic id."),
          arg("wave_id", true, "string", "Ancestry-root wave id."),
          arg("idempotency_key", true, "string", "Stable rollback replay key."),
          arg("previous_event_id", true, "string", "Current promotion event UUID."),
          arg("restore_event_id", true, "string", "Earlier event UUID or genesis."),
          arg("evidence", true, "string", "Evidence URI or durable reference."),
          arg("evidence_revision", true, "string", "Evidence revision.")
        ],
        writes: true,
        default_output: "json"
      ),
      # ── Provider-neutral chat transport (charter bp-chat-tui, D21-D24) ───
      # The nine non-streaming verbs behind the `/v1/chat` scope, which is
      # `pipe_through [:api, :require_admin]` — every route needs a data-plane
      # bearer with the global `admin` permission (D21: instance-global scope,
      # NO tenant/workspace/project/dataset column, so NO scoped_prefix). All
      # `auth_tier: "admin"` so the existence-hiding projection hides `chat.*`
      # from anon/lower-tier callers exactly like the other admin nouns. The
      # SSE route — `GET /v1/chat/sessions/:id/events` — is a builtin
      # streaming carve-out with no manifest verb (like `listen`); it is named
      # in the `chat` noun summary. `writes: true` on every non-GET verb here
      # (PDS-D302): sending a message, interrupting a run or approving a tool
      # call all have side effects, so the manifest must not advertise them as
      # read-only to the MCP bridge — same treatment as the auth.* exchanges.
      #
      # D36 CLOSED (charter D16 is the demanded confirmation). `chat` is an
      # ORTHOGONAL capability, not a rank: `tier_for_token/1` above appends a
      # `+chat` suffix to a workspace-bound `permissions: ["chat"]` Connector
      # token's base tier (mirroring RequireChatAccess.chat_scope/1's
      # `{:workspace, ws}` grant), and `project/2` honors it through the
      # `chat_visible?/2` side-branch — which widens visibility for `noun ==
      # "chat"` ONLY, lifting no other noun's tier. These commands keep
      # `auth_tier: "admin"` on the wire, so admin/ingest still discover them
      # through the rank ladder and anon/`[read,write]` callers still get `chat`
      # stripped. See the `capabilities_manifest_test.exs` "chat-capability
      # workspace token" pin for the projected-visibility guard.
      core_cmd(
        "chat.create_session",
        "chat",
        "create-session",
        "Start a provider-backed chat session with server-minted public and provider identities.",
        "POST",
        "/v1/chat/sessions",
        "admin",
        flags: [
          flag("provider", "string", "Runtime provider (claude or codex; defaults to claude)."),
          flag(
            "execution_target",
            "string",
            "Execution location (managed or registered_host; defaults to managed)."
          ),
          flag(
            "execution_host_id",
            "string",
            "Registered host UUID; required only when execution_target is registered_host."
          ),
          flag("mode", "string", "Provider-scoped permission mode (allowlisted)."),
          flag("model", "string", "Provider-scoped model choice (allowlisted)."),
          flag("effort", "string", "Provider-scoped effort choice (allowlisted).")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "chat.list_sessions",
        "chat",
        "list-sessions",
        "List chat sessions (sidebar shape; omits draft/choices — GET one session for the full struct).",
        "GET",
        "/v1/chat/sessions",
        "admin",
        flags: [
          flag("archived", "string", "Filter by archived state (query ?archived=<value>).")
        ],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "chat.get_session",
        "chat",
        "get-session",
        "Fetch one chat session in full (draft, rail, mode/model/effort, metrics) plus its messages seq-asc.",
        "GET",
        "/v1/chat/sessions/:id",
        "admin",
        args: [arg("id", true, "string", "Chat session id (the same id `bp chat` resumes on).")],
        flags: [
          flag(
            "since",
            "int",
            "Return only message rows with seq > <since> (the turn-boundary tail refetch)."
          )
        ],
        writes: false,
        default_output: "json"
      ),
      core_cmd(
        "chat.update_session",
        "chat",
        "update-session",
        "Patch a chat session's allowlisted keys (draft | mode | model_choice | effort_choice | title).",
        "PATCH",
        "/v1/chat/sessions/:id",
        "admin",
        args: [arg("id", true, "string", "Chat session id.")],
        flags: [
          flag("draft", "string", "In-progress message draft (≤64 KiB)."),
          flag("mode", "string", "Permission mode (allowlisted)."),
          flag("model_choice", "string", "Model choice (allowlisted)."),
          flag("effort_choice", "string", "Effort choice (allowlisted)."),
          flag("title", "string", "Session title (≤256 UTF-8 bytes).")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "chat.send_message",
        "chat",
        "send-message",
        "Send a message to a chat session (buffered as its own turn if one is mid-flight).",
        "POST",
        "/v1/chat/sessions/:id/messages",
        "admin",
        args: [
          arg("id", true, "string", "Chat session id."),
          arg("content", true, "string", "Message content (≤64 KiB).")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "chat.interrupt",
        "chat",
        "interrupt",
        "Interrupt a chat session's in-flight turn (no-op when no turn is active).",
        "POST",
        "/v1/chat/sessions/:id/interrupt",
        "admin",
        args: [arg("id", true, "string", "Chat session id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "chat.approve",
        "chat",
        "approve",
        "Answer a pending tool-permission ask on a chat session (allow | deny).",
        "POST",
        "/v1/chat/sessions/:id/approval",
        "admin",
        args: [
          arg("id", true, "string", "Chat session id."),
          arg(
            "request_id",
            true,
            "string",
            "The permission ask's request id (≤256 UTF-8 bytes)."
          ),
          arg("decision", true, "string", "allow | deny (never a caller-supplied updatedInput).")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "chat.archive",
        "chat",
        "archive",
        "Archive a chat session — it leaves the active sidebar for the archived shelf (idempotent; liveness untouched).",
        "POST",
        "/v1/chat/sessions/:id/archive",
        "admin",
        args: [arg("id", true, "string", "Chat session id.")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "chat.unarchive",
        "chat",
        "unarchive",
        "Unarchive a chat session — it returns from the archived shelf to the active sidebar (idempotent).",
        "POST",
        "/v1/chat/sessions/:id/unarchive",
        "admin",
        args: [arg("id", true, "string", "Chat session id.")],
        writes: true,
        default_output: "minimal"
      ),
      # ── Mobile app-token exchange (task wb-api-capabilities-undeclared-verbs)
      # Mounted at `/v1/auth/app-tokens` behind `[:api, :require_token]` — the
      # PIPELINE only proves SOME token, so auth_tier here is taken from the
      # ENFORCED gate inside AppTokenController, not the pipeline (the task's
      # non-negotiable): create/ls/revoke/revoke-by-id all additionally require
      # `Auth.has_permission?(token, "admin")` in the controller body, so they
      # carry "admin". `revoke-current` is the one exception: the bearer
      # revokes ITSELF and the controller only REFUSES an admin bearer (422) —
      # any non-admin, i.e. "read"-tier-and-up, token reaches it. Declaring it
      # "admin" would existence-hide a verb every authenticated caller can
      # actually invoke.
      core_cmd(
        "app_token.create",
        "app_token",
        "create",
        "Mint a member-shaped [read,write,chat] app token for a JIT-provisioned cloud identity.",
        "POST",
        "/v1/auth/app-tokens",
        "admin",
        args: [
          arg("email", true, "string", "Cloud account the token is minted for.")
        ],
        flags: [
          flag("workspace", "string", "Workspace slug or id to bind (default: Default Workspace)."),
          flag(
            "permissions",
            "string",
            "Comma list — read|write|chat.",
            default: "read,write,chat"
          ),
          flag("label", "string", "Human label (default: \"app:<email>\")."),
          flag("dataset", "string", "Dataset to bind.", default: "production")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "app_token.ls",
        "app_token",
        "ls",
        "List app tokens on this instance (labels redacted unless ?email= filters to one address).",
        "GET",
        "/v1/auth/app-tokens",
        "admin",
        flags: [
          flag(
            "email",
            "string",
            "Filter to one email's tokens — reveals their labels; an unfiltered list redacts every label."
          )
        ],
        writes: false,
        default_output: "table"
      ),
      core_cmd(
        "app_token.revoke",
        "app_token",
        "revoke",
        "Revoke an app token by its raw secret, or every live token for an email (logout-everywhere, confined to workspaces the caller admins).",
        "DELETE",
        "/v1/auth/app-tokens",
        "admin",
        flags: [
          flag("token", "string", "Revoke exactly this raw token."),
          flag("email", "string", "Revoke every live app token for this email.")
        ],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "app_token.revoke-by-id",
        "app_token",
        "revoke-by-id",
        "Revoke an app token by its row id — the escape hatch for a custom-labelled token.",
        "DELETE",
        "/v1/auth/app-tokens/:id",
        "admin",
        args: [arg("id", true, "string", "App-token row id (from app_token ls).")],
        writes: true,
        default_output: "minimal"
      ),
      core_cmd(
        "app_token.revoke-current",
        "app_token",
        "revoke-current",
        "Self-revoke the app token sent as the bearer — possession is the authorization, no admin required (admin bearers are refused).",
        "DELETE",
        "/v1/auth/app-tokens/current",
        "read",
        writes: true,
        default_output: "minimal"
      ),
      # ── Personal Dev Fleet support tokens (PDF-D57/D60; task
      # wb-api-capabilities-undeclared-verbs). Mounted under :flat_admin_api,
      # which re-runs the same RequireAdmin global-permission gate as the flat
      # [:api, :require_admin] pipeline (only the workspace-derivation order
      # differs) — same "admin" tier as share.* above on that pipeline.
      core_cmd(
        "fleet_support_token.create",
        "fleet_support_token",
        "create",
        "Mint a write-capable, attributable support token for a remote Personal Dev Fleet machine.",
        "POST",
        "/v1/fleet/support-tokens",
        "admin",
        args: [
          arg(
            "name",
            true,
            "string",
            "Support actor name — the stored label is fleet-support-<name>."
          )
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "fleet_support_token.revoke",
        "fleet_support_token",
        "revoke",
        "Revoke a support token by id (confined to the fleet-support- family, in a workspace the caller admins).",
        "DELETE",
        "/v1/fleet/support-tokens/:token_id",
        "admin",
        args: [arg("token_id", true, "string", "Support token id (from fleet_support_token create).")],
        writes: true,
        default_output: "minimal"
      ),
      # ── Status-page incidents (task wb-api-capabilities-undeclared-verbs).
      # Mounted at /v1/status/incidents behind [:api, :require_admin] — same
      # "admin" global tier as share.ls/add/rm and the fleet/incident siblings
      # on that exact pipeline.
      core_cmd(
        "incident.create",
        "incident",
        "create",
        "Open a status-page incident.",
        "POST",
        "/v1/status/incidents",
        "admin",
        args: [
          arg("title", true, "string", "Incident title."),
          arg("started_at", true, "string", "RFC-3339 incident start time.")
        ],
        flags: [
          flag("component", "string", "Affected component."),
          flag("impact", "string", "none | minor | major | critical.", default: "minor"),
          flag(
            "status",
            "string",
            "investigating | identified | monitoring | resolved.",
            default: "investigating"
          ),
          flag("body", "string", "Incident body/description.")
        ],
        writes: true,
        default_output: "json"
      ),
      core_cmd(
        "incident.resolve",
        "incident",
        "resolve",
        "Resolve a status-page incident.",
        "POST",
        "/v1/status/incidents/:id/resolve",
        "admin",
        args: [arg("id", true, "string", "Incident id.")],
        writes: true,
        default_output: "minimal"
      )
    ]
  end

  # Build a fully-formed core command map (string keys, all required fields).
  defp core_cmd(id, noun, verb, summary, method, path, auth_tier, opts) do
    base = %{
      "id" => id,
      "noun" => noun,
      "verb" => verb,
      "summary" => summary,
      "http" => %{"method" => method, "path_template" => path},
      "auth_tier" => auth_tier,
      "args" => Keyword.get(opts, :args, []),
      "flags" => Keyword.get(opts, :flags, []),
      # REQUIRED, never defaulted (PDS-D302): a `writes` that fails open is how
      # 16 mutators shipped advertised as read-only. `core_commands/0` is a
      # runtime function, so this raises on the first /v1/capabilities request,
      # not at boot — the manifest contract test is the real guard, and every
      # call site must state the bit out loud.
      "writes" => Keyword.fetch!(opts, :writes),
      "batch" => Keyword.get(opts, :batch, false),
      "paginated" => Keyword.get(opts, :paginated, false),
      "dry_run" => Keyword.get(opts, :dry_run, false),
      "default_output" => Keyword.get(opts, :default_output, "table"),
      "source" => "core"
    }

    base =
      case Keyword.fetch(opts, :mutation_op) do
        {:ok, op} -> Map.put(base, "mutation_op", op)
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :set_key) do
        {:ok, key} -> Map.put(base, "set_key", key)
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :views) do
        {:ok, views} -> Map.put(base, "views", views)
        :error -> base
      end

    case Keyword.fetch(opts, :scoped_prefix) do
      {:ok, prefix} -> Map.put(base, "scoped_prefix", prefix)
      :error -> base
    end
  end

  defp arg(name, required, type, summary) do
    %{"name" => name, "required" => required, "type" => type, "summary" => summary}
  end

  defp flag(name, type, summary, opts \\ []) do
    base = %{"name" => name, "type" => type, "summary" => summary}

    base
    |> maybe_put("default", Keyword.fetch(opts, :default))
    |> maybe_put("repeatable", Keyword.fetch(opts, :repeatable))
  end

  defp maybe_put(map, key, {:ok, value}), do: Map.put(map, key, value)
  defp maybe_put(map, _key, :error), do: map
end
