defmodule Barkpark.Sites.DeployRequest do
  @moduledoc """
  A VALIDATED site-deploy invocation — the only thing
  `Barkpark.Sites.DeployRunner` will run.

  This struct is the choke point between untrusted admin request params and
  an OS process: nothing reaches argv or the child's environment until it has
  survived `new/1`. `slug` and `build_id` are re-validated INDEPENDENTLY by
  `deploy/site-deploy.sh` itself (same two regexes) — that is deliberate
  defense in depth, not redundancy: either layer alone is a single point of
  failure for a value that names a filesystem path.

  Shape (charter D22, D63):

      %{
        "slug"           => "my-blog",        # ^[a-z0-9][a-z0-9-]{0,62}$
        "build_id"       => "a1b2c3d4",       # ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ (deploy only)
        "content_rev"    => "1f2e...",        # optional, baked as bp-content-rev
        "mode"           => "deploy" | "rollback" | "teardown",
        "runtime_target" => "static" | "node",# where the artifact runs (default "static")
        "template"       => "astro-starter" | "next-starter" | "search-starter" | "astro-search-starter", # which starter (optional)
        "env"            => %{"BARKPARK_API_URL" => _, "BARKPARK_TOKEN" => _, ...}
      }

  `template` (search-template charter D7) is the THIRD axis — WHICH shipped
  starter tree the Provisioner materializes. It is a CLOSED enum, validated
  EXACTLY like `mode`/`runtime_target`, because the value indexes a filesystem
  path (`templates/<slug>`) — an open string there is a path-traversal /
  arbitrary-source seam. `nil` (absent) is the backward-compatible default: the
  Provisioner then derives the template from `runtime_target` (static→astro,
  node→next), so every pre-template caller is unaffected.

  `runtime_target` (charter D63) is the SECOND axis of the deploy engine — the
  "ONE state machine, TWO runtime targets" split. `"static"` (the default,
  backward-compatible) is the symlink-swap target the box has always run;
  `"node"` is the node-slot SSR target (a long-running `next start` process the
  box supervises). It is a CLOSED enum, validated exactly like `mode`: an
  unrecognized value is a 400, NEVER `String.to_atom` on request data, because
  this value chooses which engine script reaches argv (and, later, a systemd
  slot unit NAME) — an open string there is a command/unit-injection seam.

  `env` is a CLOSED allow-list (`allowed_env_keys/0`) — an unknown key is a
  400, never a silent drop, because a caller that thinks it is passing a build
  var we quietly ignore would ship a site built against the wrong content.

  `artifact_b64` + `artifact_sha256` (charter D86/D87 — the build leaves the
  serving box) are the PREBUILT pair: a base64 `.tar.gz` of an already-built
  `dist/` plus the digest the caller says it has. They are FIRST-CLASS struct
  fields, deliberately NOT `env` keys — `env` is the caller-supplied BUILD var
  allow-list and caps every value at 4096 bytes, three orders of magnitude
  under a real bundle.

  They are validated as a PAIR and are `mode: "deploy"` only, because the
  alternative is the exact failure this closes: before this change an unknown
  top-level param was SILENTLY DROPPED by `new/1`, so a control plane that
  believed it had shipped prebuilt bytes to an un-upgraded box would get
  `{:ok, req}` with no artifact, the box would rebuild from the template, HEALTH
  would pass on genuine markers, and the site would go live with the WRONG
  bytes. Half a handshake is worse than none: either both keys validate or the
  request is a 400.
  """

  @enforce_keys [:slug, :mode]
  defstruct slug: nil,
            build_id: nil,
            content_rev: nil,
            mode: :deploy,
            runtime_target: :static,
            template: nil,
            artifact_b64: nil,
            artifact_sha256: nil,
            env: %{}

  @type t :: %__MODULE__{
          slug: String.t(),
          build_id: String.t() | nil,
          content_rev: String.t() | nil,
          mode: :deploy | :rollback | :teardown,
          runtime_target: :static | :node,
          template:
            :astro_starter | :next_starter | :search_starter | :astro_search_starter | nil,
          artifact_b64: String.t() | nil,
          artifact_sha256: String.t() | nil,
          env: %{optional(String.t()) => String.t()}
        }

  # The engine's BUILD_ALLOW set, minus the two it derives itself from
  # SITE_SLUG/BUILD_ID (BARKPARK_BUILD_ID, BARKPARK_SITE_BASE are exported by
  # site-deploy.sh) — these are the vars a CALLER must supply per site.
  @allowed_env_keys ~w(
    BARKPARK_API_URL
    BARKPARK_TOKEN
    BARKPARK_DATASET
    BARKPARK_WORKSPACE
    BARKPARK_PROJECT
    BARKPARK_SITE_BASE
    BARKPARK_DOC_TYPE
    BARKPARK_THEME
  )

  # Same regexes site-deploy.sh enforces (SITE_SLUG / BUILD_ID). Anchored with
  # \A..\z, NOT ^..$ — in Elixir `$` also matches before a trailing newline, so
  # `^[a-z0-9-]+$` would happily accept "ok\n../../etc".
  @slug_re ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @build_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  # content_rev is opaque to us (a dataset revision — hash, ULID or integer);
  # bound it and keep it shell/path-inert.
  @content_rev_re ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

  # A lowercase-hex SHA-256, anchored \A..\z for the SAME reason as the others:
  # `^[0-9a-f]{64}$` would accept "…\n" and the value is compared against a
  # digest we compute ourselves.
  @artifact_digest_re ~r/\A[0-9a-f]{64}\z/
  # Base64's own alphabet, anchored. Whitespace is tolerated INSIDE (a wrapped
  # body is a legitimate encoder choice) but nothing else is.
  @artifact_b64_re ~r{\A[A-Za-z0-9+/=\s]+\z}

  @max_env_value_bytes 4096

  # The raw (decoded) artifact cap. 32 MiB is ~2x the largest shippable output
  # the charter measured (a Next standalone at 18 MB; an Astro `dist/` is 12–16
  # KB), and it bounds the base64 body a single admin request may carry.
  @max_artifact_bytes 32 * 1024 * 1024
  # base64 is 4/3 + padding + newlines; refuse an oversized STRING before
  # spending a decode on it.
  @max_artifact_b64_bytes div(@max_artifact_bytes * 4, 3) + 64 * 1024

  @doc "The env vars a caller may supply. Anything else is rejected."
  @spec allowed_env_keys() :: [String.t()]
  def allowed_env_keys, do: @allowed_env_keys

  @doc "The decoded-artifact byte cap enforced by `new/1`."
  @spec max_artifact_bytes() :: pos_integer()
  def max_artifact_bytes, do: @max_artifact_bytes

  @doc """
  Validate raw (string-keyed) request params into a `%DeployRequest{}`.

  Returns `{:error, code, message}` with a machine-readable `code`
  (`invalid_slug` | `invalid_build_id` | `invalid_content_rev` |
  `invalid_deploy_mode` | `invalid_runtime_target` | `invalid_template` |
  `invalid_env` | `invalid_artifact` | `invalid_artifact_digest` |
  `artifact_too_large`) on any violation.
  """
  @spec new(map()) :: {:ok, t()} | {:error, String.t(), String.t()}
  def new(params) when is_map(params) do
    with {:ok, slug} <- validate_slug(Map.get(params, "slug")),
         {:ok, mode} <- validate_mode(Map.get(params, "mode")),
         {:ok, runtime_target} <- validate_runtime_target(Map.get(params, "runtime_target")),
         {:ok, template} <- validate_template(Map.get(params, "template")),
         {:ok, build_id} <- validate_build_id(mode, Map.get(params, "build_id")),
         {:ok, content_rev} <- validate_content_rev(Map.get(params, "content_rev")),
         {:ok, artifact_b64, artifact_sha256} <-
           validate_artifact(
             mode,
             Map.get(params, "artifact_b64"),
             Map.get(params, "artifact_sha256")
           ),
         {:ok, env} <- validate_env(Map.get(params, "env")) do
      {:ok,
       %__MODULE__{
         slug: slug,
         build_id: build_id,
         content_rev: content_rev,
         mode: mode,
         runtime_target: runtime_target,
         template: template,
         artifact_b64: artifact_b64,
         artifact_sha256: artifact_sha256,
         env: env
       }}
    end
  end

  def new(_params), do: {:error, "invalid_request", "request body must be an object"}

  @doc """
  Validate a site slug on its own — the status read (`GET ?slug=`) names a slug
  and nothing else, and it must be held to the SAME regex as the write path.
  """
  @spec validate_slug(term()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def validate_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_re, slug),
      do: {:ok, slug},
      else: {:error, "invalid_slug", "slug must match ^[a-z0-9][a-z0-9-]{0,62}$"}
  end

  def validate_slug(_slug),
    do: {:error, "invalid_slug", "slug is required and must match ^[a-z0-9][a-z0-9-]{0,62}$"}

  # Default mode is the primary verb; anything outside the whitelist is a 400
  # (never String.to_atom on request data).
  defp validate_mode(nil), do: {:ok, :deploy}
  defp validate_mode("deploy"), do: {:ok, :deploy}
  defp validate_mode("rollback"), do: {:ok, :rollback}
  defp validate_mode("teardown"), do: {:ok, :teardown}

  defp validate_mode(_mode),
    do: {:error, "invalid_deploy_mode", ~s(mode must be "deploy", "rollback", or "teardown")}

  # Runtime target is a CLOSED enum, validated EXACTLY like mode (charter D63):
  # it picks which engine script reaches argv — and later a systemd slot unit
  # NAME — so an open string is a command/unit-injection seam. Default "static"
  # keeps every existing (pre-node) caller on the symlink-swap target.
  defp validate_runtime_target(nil), do: {:ok, :static}
  defp validate_runtime_target("static"), do: {:ok, :static}
  defp validate_runtime_target("node"), do: {:ok, :node}

  defp validate_runtime_target(_target),
    do: {:error, "invalid_runtime_target", ~s(runtime_target must be "static" or "node")}

  # Template is the template-slug axis (search-template charter D7): WHICH
  # shipped starter tree the Provisioner materializes. A CLOSED enum, validated
  # EXACTLY like mode/runtime_target — the value indexes a filesystem path
  # (`templates/<slug>`), so an open string is a path-traversal / arbitrary-
  # source seam (never String.to_atom on request data). `nil` (absent) is the
  # backward-compatible default: the Provisioner derives the template from
  # runtime_target (static→astro, node→next), so pre-template callers are
  # unaffected.
  defp validate_template(nil), do: {:ok, nil}
  defp validate_template("astro-starter"), do: {:ok, :astro_starter}
  defp validate_template("next-starter"), do: {:ok, :next_starter}
  defp validate_template("search-starter"), do: {:ok, :search_starter}
  defp validate_template("astro-search-starter"), do: {:ok, :astro_search_starter}

  defp validate_template(_template),
    do:
      {:error, "invalid_template",
       ~s(template must be one of "astro-starter", "next-starter", "search-starter", "astro-search-starter")}

  # A rollback is a pure symlink repoint — the engine reads .previous, not a
  # build_id — so we drop any build_id passed with one rather than feed the
  # child an argument its mode ignores.
  defp validate_build_id(:rollback, _build_id), do: {:ok, nil}
  defp validate_build_id(:teardown, _build_id), do: {:ok, nil}

  defp validate_build_id(:deploy, build_id) when is_binary(build_id) do
    if Regex.match?(@build_id_re, build_id),
      do: {:ok, build_id},
      else: {:error, "invalid_build_id", "build_id must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"}
  end

  defp validate_build_id(:deploy, _build_id),
    do: {:error, "invalid_build_id", "build_id is required for mode=deploy"}

  defp validate_content_rev(nil), do: {:ok, nil}
  defp validate_content_rev(""), do: {:ok, nil}

  defp validate_content_rev(rev) when is_binary(rev) do
    if Regex.match?(@content_rev_re, rev),
      do: {:ok, rev},
      else:
        {:error, "invalid_content_rev",
         "content_rev must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"}
  end

  defp validate_content_rev(_rev),
    do: {:error, "invalid_content_rev", "content_rev must be a string"}

  @doc """
  Is this request carrying a prebuilt artifact? True only when BOTH keys
  survived `new/1` — the two are validated as a pair, so a half-set struct is
  unrepresentable.
  """
  @spec prebuilt?(t()) :: boolean()
  def prebuilt?(%__MODULE__{artifact_b64: b64, artifact_sha256: sha})
      when is_binary(b64) and is_binary(sha),
      do: true

  def prebuilt?(%__MODULE__{}), do: false

  # ── the prebuilt pair ───────────────────────────────────────────────────
  #
  # The two keys are validated TOGETHER and refused loudly. Every branch below
  # that returns an error is a case that used to be a SILENT DROP: `new/1` read
  # only the keys it knew, so `artifact_b64` on an un-upgraded box produced
  # {:ok, req} with no artifact and a box-built site that passes HEALTH.
  defp validate_artifact(_mode, nil, nil), do: {:ok, nil, nil}
  defp validate_artifact(_mode, "", nil), do: {:ok, nil, nil}
  defp validate_artifact(_mode, nil, ""), do: {:ok, nil, nil}
  defp validate_artifact(_mode, "", ""), do: {:ok, nil, nil}

  defp validate_artifact(mode, b64, sha) when mode != :deploy and (b64 != nil or sha != nil),
    do:
      {:error, "invalid_artifact",
       "artifact_b64/artifact_sha256 are only valid with mode=deploy " <>
         "(a rollback repoints a symlink; a teardown removes a site)"}

  defp validate_artifact(_mode, b64, sha) when is_binary(b64) and not is_binary(sha),
    do:
      {:error, "invalid_artifact_digest",
       "artifact_sha256 is required with artifact_b64 (a prebuilt artifact is " <>
         "only accepted with the digest it must match)"}

  defp validate_artifact(_mode, b64, sha) when not is_binary(b64) and is_binary(sha),
    do:
      {:error, "invalid_artifact",
       "artifact_b64 is required with artifact_sha256 — a digest alone deploys nothing"}

  defp validate_artifact(_mode, b64, sha) when is_binary(b64) and is_binary(sha) do
    with {:ok, sha} <- validate_artifact_digest(sha),
         {:ok, b64} <- validate_artifact_b64(b64) do
      {:ok, b64, sha}
    end
  end

  defp validate_artifact(_mode, _b64, _sha),
    do: {:error, "invalid_artifact", "artifact_b64 and artifact_sha256 must be strings"}

  defp validate_artifact_digest(sha) do
    if Regex.match?(@artifact_digest_re, sha),
      do: {:ok, sha},
      else:
        {:error, "invalid_artifact_digest", "artifact_sha256 must be 64 lowercase hex characters"}
  end

  # Cheap checks first (STRING size, then alphabet), and only then the decode —
  # so a 400 MB body costs a byte_size, not a 400 MB allocation. The decoded
  # bytes are discarded here: this is the gate, not the ingest.
  # `Barkpark.Sites.PrebuiltArtifact` decodes for real.
  defp validate_artifact_b64(b64) do
    cond do
      byte_size(b64) > @max_artifact_b64_bytes ->
        {:error, "artifact_too_large", "artifact exceeds #{@max_artifact_bytes} bytes (decoded)"}

      not Regex.match?(@artifact_b64_re, b64) ->
        {:error, "invalid_artifact", "artifact_b64 must be base64"}

      true ->
        decode_artifact_b64(b64)
    end
  end

  defp decode_artifact_b64(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, raw} when byte_size(raw) > @max_artifact_bytes ->
        {:error, "artifact_too_large",
         "artifact is #{byte_size(raw)} bytes decoded, over the #{@max_artifact_bytes} byte cap"}

      {:ok, ""} ->
        {:error, "invalid_artifact", "artifact_b64 decodes to zero bytes"}

      {:ok, _raw} ->
        {:ok, b64}

      :error ->
        {:error, "invalid_artifact", "artifact_b64 must be base64"}
    end
  end

  defp validate_env(nil), do: {:ok, %{}}

  defp validate_env(env) when is_map(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case validate_env_pair(key, value) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _code, _msg} = error -> {:halt, error}
      end
    end)
  end

  defp validate_env(_env), do: {:error, "invalid_env", "env must be an object"}

  defp validate_env_pair(key, value) when is_binary(key) and is_binary(value) do
    cond do
      key not in @allowed_env_keys ->
        {:error, "invalid_env",
         "unknown env var #{inspect(key)} (allowed: #{Enum.join(@allowed_env_keys, ", ")})"}

      byte_size(value) > @max_env_value_bytes ->
        {:error, "invalid_env", "env var #{key} exceeds #{@max_env_value_bytes} bytes"}

      # NUL truncates a C string mid-value; CR/LF would forge a line in the
      # very stream we parse BPSTAGE out of. Neither belongs in an env value.
      String.contains?(value, ["\0", "\n", "\r"]) ->
        {:error, "invalid_env", "env var #{key} contains a control character"}

      true ->
        {:ok, key, value}
    end
  end

  defp validate_env_pair(key, _value) when is_binary(key),
    do: {:error, "invalid_env", "env var #{key} must be a string"}

  defp validate_env_pair(_key, _value),
    do: {:error, "invalid_env", "env keys must be strings"}
end
