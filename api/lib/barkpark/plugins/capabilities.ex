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
    commands = Map.get(manifest, "commands", [])
    nouns = Map.get(manifest, "nouns", [])

    visible_commands =
      Enum.filter(commands, fn cmd -> visible?(command_tier(cmd), caller_tier) end)

    visible_noun_names =
      visible_commands
      |> Enum.map(&command_noun/1)
      |> MapSet.new()

    visible_nouns =
      Enum.filter(nouns, fn noun -> MapSet.member?(visible_noun_names, noun_name(noun)) end)

    projected =
      manifest
      |> Map.put("auth_tier", caller_tier)
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
  """
  @spec tier_for_token(struct() | nil) :: tier()
  def tier_for_token(nil), do: "none"

  def tier_for_token(token) do
    alias Barkpark.Tenancy.Auth, as: TenancyAuth

    cond do
      TenancyAuth.permits?(token, :admin) -> "admin"
      TenancyAuth.permits?(token, :write) -> "write"
      TenancyAuth.permits?(token, :read) -> "read"
      true -> "none"
    end
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

    %{
      "manifest_version" => @manifest_version,
      "server" => server,
      "auth_tier" => caller_tier,
      "generated_at" => generated_at,
      "etag" => "",
      "nouns" => core_nouns ++ plugin_nouns,
      "commands" => core_commands ++ plugin_commands
    }
    |> then(fn m -> Map.put(m, "etag", etag_for(m)) end)
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

  defp default_server do
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
      # be able to DISCOVER login); the 4 session-gated verbs are "read"
      # (existence-hidden from anon, shown to any authenticated caller). NOTE:
      # the session-gated verbs require a USER session, not an api_token, so bp
      # itself cannot drive them — they are surfaced for discovery/docs.
      %{
        "name" => "auth",
        "summary" => "User accounts — register, login, sessions, MFA.",
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
          )
        ],
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
          flag("limit", "int", "Max rows to return.", default: 50),
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
            "field<op>value where op is = != > >= < <= ^= (starts) $= (ends) *= (contains) (e.g. status=published, slug^=2024-, title*=hello); or 'field in a,b,c' / 'field not in a,b,c'; or 'field is null' / 'field is not null'.",
            repeatable: false
          ),
          flag(
            "fields",
            "string",
            "Return only these content fields (projection): a comma list. System fields (_id, _type, …) always included."
          ),
          flag("limit", "int", "Max rows to return.", default: 50),
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
        "media.collections",
        "media",
        "collections",
        "List media collections (folders / smart-folders).",
        "GET",
        "/v1/media/:dataset/collections",
        "none",
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
          flag("perspective", "string", "published (default) | drafts | raw.")
        ],
        paginated: true,
        default_output: "table",
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
        default_output: "table"
      ),
      core_cmd(
        "workspace.create",
        "workspace",
        "create",
        "Create a new workspace owned by the caller (+ Default project + production dataset).",
        "POST",
        "/api/workspaces",
        "write",
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
        default_output: "table"
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
      core_cmd(
        "plugin.ls",
        "plugin",
        "ls",
        "List installed plugins.",
        "GET",
        "/v1/plugins",
        "admin",
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
      core_cmd(
        "share.ls",
        "share",
        "ls",
        "List scoped network shares (env baseline + persisted).",
        "GET",
        "/v1/shares",
        "admin",
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
        default_output: "json"
      ),
      # ── Core user auth (login/sessions/MFA/email flows) ──────────────────
      # Pre-tenant, global (no scoped_prefix). The 5 public verbs are tier
      # "none" so an anon caller can discover login; the 4 session-gated verbs
      # are tier "read" (hidden from anon, shown to any authenticated caller).
      # writes:false for all — these are auth exchanges, not content mutations
      # (the manifest `writes` flag drives bp's content --dry-run/confirm path).
      # Paths mirror router.ex /v1/auth/* (public 716-724, gated 727-734).
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
        default_output: "json"
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
      "writes" => Keyword.get(opts, :writes, false),
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
