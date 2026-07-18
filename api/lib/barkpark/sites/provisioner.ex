defmodule Barkpark.Sites.Provisioner do
  @moduledoc """
  Site SOURCE PROVISIONING — the missing link between "a content-bound Astro
  site exists" and "there is something on the box for BUILD to compile"
  (site-spawner charter D33/D34).

  A content-bound site has no `github_repo` and no `artifact_url`: its source IS
  a shipped starter template, which fetches Barkpark content at build time over
  the internal link and bakes the HEALTH markers. Nothing materialized that
  template onto the box, so `deploy/site-deploy.sh` walked PLAN and then died at
  BUILD with `no site source dir /opt/barkpark/sites/<slug>/src` (exit 10).

  ## Which template (charter D63/D71, search-template D7)

  The template is a KEYED LOOKUP over `@templates`, selected by the request's
  `template` slug — the third axis of the deploy engine:

    * `:astro_starter` → `templates/astro-starter` — the Astro symlink-swap site;
    * `:next_starter` → `templates/next-starter` — the Next.js node-slot SSR site;
    * `:search_starter` → `templates/search-starter` — the flagship search app
      (finder + graph + map, node-slot SSR).

  A request WITHOUT a `template` derives its default from `runtime_target`
  (static→astro, node→next — see `resolve_template/2`), so every pre-template
  caller lands EXACTLY where it did before. Everything BELOW the selection
  (partial-rename atomicity, the `.bp-provisioned` marker, self-heal,
  fail-closed) is framework-agnostic and identical for all templates.

  `provision/1` runs INLINE at the top of `DeployRunner.start_run/2`, for a
  `deploy` only (a `rollback` is a pure symlink/slot repoint — the source is
  already there, and re-materializing it would be both pointless and
  destructive), and copies the selected template into `<sites_dir>/<slug>/src`
  BEFORE the deploy port opens.

  ## The path formula (identical to site-deploy.sh)

  `site-deploy.sh` resolves `SITES_DIR="${BARKPARK_SITES_DIR:-/opt/barkpark/sites}"`,
  `ROOT="$SITES_DIR/$SITE_SLUG"`, `SITE_SRC="${SITE_SRC:-$ROOT/src}"`. We MUST
  land the template at the exact same `<sites_dir>/<slug>/src` the engine reads,
  or BUILD still finds nothing. Both `sites_dir` and the template path are
  configurable (Application env, wired from `runtime.exs`) so a test points them
  at a tmp dir instead of `/opt/barkpark`.

  ## Fail-closed + idempotent (charter D34)

    * **Atomic materialize.** The template is copied into a `src.partial`
      sibling FIRST; only once the whole copy is on disk is the live `src`
      swapped for it via `rename(2)` — the literal analog of
      site-deploy.sh:789-795's STAGE idiom. A crash mid-copy dies in
      `src.partial`, never in a half-populated `src` that a later BUILD would
      mistake for a real checkout.
    * **Marker-guarded no-op, CONTENT-fresh.** A `.bp-provisioned` marker is
      written INSIDE `src` ONLY after the rename, recording the template slug +
      a content digest of the template tree. A redeploy is a no-op ONLY while
      both still match — so a content-only redeploy keeps the site's
      `node_modules`/`dist` build cache, while a template UPDATE (or a template
      switch on the same slug) re-materializes instead of serving stale source
      forever (search-template W1 live-proof fix).
    * **Self-healing.** A `src` left WITHOUT its marker (a prior provision that
      died between rename and marker, or a hand-mangled dir) is NOT trusted —
      the next provision re-materializes it from scratch.
    * **Fail-closed.** Any failure (missing template, unwritable sites dir, a
      failed rename) returns `{:error, {:provision_failed, reason}}`. The caller
      short-circuits exactly like an `open_port/1` failure: it NEVER opens the
      deploy Port, so a deploy whose source could not be materialized dies
      before it can run against nothing.
  """

  alias Barkpark.Sites.DeployRequest

  # Same default as site-deploy.sh's `${BARKPARK_SITES_DIR:-/opt/barkpark/sites}`.
  @default_sites_dir "/opt/barkpark/sites"

  # The template registry (search-template charter D7): each shipped starter maps
  # to its Application-env override KEY and its default repo-relative SUBPATH. The
  # `template` axis on the request selects a row directly; a request without one
  # derives its default from runtime_target (resolve_template/2). Adding a starter
  # is one row here + one clause in DeployRequest.validate_template/1 + its env
  # override in runtime.exs. The default subpaths are relative to the repo root:
  # the BEAM's cwd is api/ under both `mix phx.server` and start.sh, so its parent
  # is the repo root — the same assumption DeployRunner.run_cd/0 makes for
  # `bash deploy/…`.
  @templates %{
    astro_starter: {:template_dir, "templates/astro-starter"},
    next_starter: {:node_template_dir, "templates/next-starter"},
    search_starter: {:search_template_dir, "templates/search-starter"},
    astro_search_starter: {:astro_search_template_dir, "templates/astro-search-starter"}
  }

  # Written INSIDE src after the rename — its presence is the idempotency guard.
  @marker ".bp-provisioned"

  @doc "The `Barkpark.Sites.Provisioner` config keyword list (see runtime.exs)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:barkpark, __MODULE__, [])

  @doc """
  Materialize the site template into `<sites_dir>/<slug>/src` for a DEPLOY.

  A `rollback` request is a no-op (`:ok`) — its source already exists.
  Idempotent for a `deploy` (a marker-guarded no-op if already provisioned),
  fail-closed (`{:error, {:provision_failed, reason}}` on any error, and never a
  half-materialized `src`). Never raises.
  """
  @spec provision(DeployRequest.t()) :: :ok | {:error, {:provision_failed, term()}}
  def provision(%DeployRequest{mode: :rollback}), do: :ok
  # A teardown deletes the site — there is nothing to materialize (like a rollback).
  def provision(%DeployRequest{mode: :teardown}), do: :ok

  def provision(%DeployRequest{
        mode: :deploy,
        slug: slug,
        runtime_target: runtime_target,
        template: template
      }) do
    src = src_dir(slug)
    template_key = resolve_template(template, runtime_target)
    template_path = template_dir(template_key)
    digest = template_digest(template_path)

    if provisioned_fresh?(src, template_key, digest) do
      :ok
    else
      materialize(src, template_path, template_key, digest)
    end
  rescue
    # A bang File op (cp_r!/mkdir_p!/rm_rf! on unwritable/absent paths) raises —
    # degrade to a fail-closed error, never let it crash the DeployRunner.
    error -> {:error, {:provision_failed, error}}
  catch
    kind, reason -> {:error, {:provision_failed, {kind, reason}}}
  end

  @doc "The `src` dir this slug provisions into: `<sites_dir>/<slug>/src`."
  @spec src_dir(String.t()) :: String.t()
  def src_dir(slug) when is_binary(slug), do: Path.join([sites_dir(), slug, "src"])

  # ── materialize ───────────────────────────────────────────────────────────

  defp materialize(src, template, template_key, digest) do
    cond do
      not File.dir?(template) ->
        {:error, {:provision_failed, {:template_not_found, template}}}

      true ->
        partial = src <> ".partial"

        # Build the full copy in `src.partial` FIRST, then flip. If cp_r! fails
        # partway, `src` is untouched (still the good prior source, or absent).
        File.rm_rf!(partial)
        File.mkdir_p!(Path.dirname(src))
        File.cp_r!(template, partial)
        File.rm_rf!(src)

        case File.rename(partial, src) do
          :ok ->
            # Marker LAST — a src without it is never trusted (self-healing).
            File.write!(Path.join(src, @marker), marker_body(template_key, digest))
            :ok

          {:error, reason} ->
            File.rm_rf!(partial)
            {:error, {:provision_failed, {:rename_failed, reason}}}
        end
    end
  end

  # Freshness guard (search-template W1 live-proof fix): the marker records WHICH
  # template materialized this src and a content digest of that template tree.
  # A provision is a no-op ONLY when both still match — so a template update (or
  # a template SWITCH on an existing slug) re-materializes instead of silently
  # serving stale source forever (proven live: search-capstone kept building a
  # pre-.basepath tree until the src was hand-cleared). A legacy marker without
  # template=/digest= lines fails the match and re-materializes once — the safe
  # upgrade path. Build caches (node_modules) survive only unchanged-template
  # redeploys, which is exactly the boundary we want: same inputs, same cache.
  defp provisioned_fresh?(src, template_key, digest) do
    case File.read(Path.join(src, @marker)) do
      {:ok, body} ->
        fields =
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "=", parts: 2) do
              [k, v] -> [{k, v}]
              _ -> []
            end
          end)
          |> Map.new()

        fields["template"] == Atom.to_string(template_key) and fields["digest"] == digest

      {:error, _} ->
        false
    end
  end

  # sha256 over every file's relative path + content, path-sorted — a pure
  # function of the template tree's bytes (never mtimes, which churn per
  # checkout). ~40MB templates hash in well under a second; the cost buys the
  # no-op/rematerialize decision being CONTENT-true.
  defp template_digest(template) do
    case File.dir?(template) do
      false ->
        "absent"

      true ->
        template
        |> tree_files()
        |> Enum.sort()
        |> Enum.reduce(:crypto.hash_init(:sha256), fn rel, acc ->
          acc
          |> :crypto.hash_update(rel)
          |> :crypto.hash_update(File.read!(Path.join(template, rel)))
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)
    end
  end

  defp tree_files(root), do: tree_files(root, "")

  defp tree_files(root, rel) do
    abs = if rel == "", do: root, else: Path.join(root, rel)

    Enum.flat_map(File.ls!(abs), fn name ->
      child_rel = if rel == "", do: name, else: Path.join(rel, name)
      child_abs = Path.join(root, child_rel)

      cond do
        File.dir?(child_abs) -> tree_files(root, child_rel)
        true -> [child_rel]
      end
    end)
  end

  defp marker_body(template_key, digest) do
    "provisioned-at=#{DateTime.utc_now() |> DateTime.to_iso8601()}\ntemplate=#{template_key}\ndigest=#{digest}\n"
  end

  # ── config resolution ─────────────────────────────────────────────────────

  defp sites_dir, do: Keyword.get(config(), :sites_dir) || @default_sites_dir

  # The effective template (search-template charter D7): an explicit request
  # `template` wins; a nil one falls back to the runtime_target default
  # (static→astro, node→next), so a caller that never sets `template` behaves
  # EXACTLY as before this axis existed.
  defp resolve_template(nil, :node), do: :next_starter
  defp resolve_template(nil, _static), do: :astro_starter
  defp resolve_template(template, _runtime_target), do: template

  # Keyed lookup over @templates (charter D63/D71/D7). Each starter has its own
  # overridable config key (falling back to its repo subpath) so a test/box can
  # point any one at a stand-in. `fetch!` on an unknown slug raises — but
  # DeployRequest's closed enum + resolve_template/2 mean only known atoms reach
  # here, and a stray one is caught by provision/1's rescue (fail-closed).
  defp template_dir(template) do
    {config_key, subpath} = Map.fetch!(@templates, template)
    Keyword.get(config(), config_key) || default_template_dir(subpath)
  end

  defp default_template_dir(subpath),
    do: Path.join(Path.dirname(File.cwd!()), subpath)
end
