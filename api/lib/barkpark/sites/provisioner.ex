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

    * **Swap, never delete-then-fill.** The template is copied into a
      `src.partial` sibling FIRST; the live `src` is then moved ASIDE to
      `src.stale` with `rename(2)` and `src.partial` is renamed into its place.
      The old tree is unlinked only AFTER the new one is live. Nothing ever
      deletes files out of a live `src` — see "the delete window" below.
    * **Marker-guarded no-op, CONTENT-fresh.** A `.bp-provisioned` marker is
      written into the staged tree BEFORE the swap (so the rename is the single
      commit point and a live `src` is never unmarked), recording the template
      slug + a content digest of the template tree. A redeploy is a no-op ONLY
      while both still match — so a content-only redeploy keeps the site's
      `node_modules`/`dist` build cache, while a template UPDATE (or a template
      switch on the same slug) re-materializes instead of serving stale source
      forever (search-template W1 live-proof fix).
    * **Integrity, not just provenance.** The marker alone attests to WHERE the
      tree came from; it says nothing about whether the tree is still all
      there. So freshness ALSO requires every path of the template manifest to
      still exist in `src` — a mutilated `src` re-materializes even though the
      template digest is unchanged (see "the delete window").
    * **Self-healing.** A `src` left WITHOUT its marker (a hand-mangled dir), or
      missing template files, or an interrupted swap (`src` absent with a
      `src.stale`/`src.partial` sibling) is NOT trusted — the next provision
      re-materializes it from scratch.
    * **Serialized per slug.** The whole check-then-materialize runs inside a
      `:global` lock keyed on the slug, so two same-slug deploys in flight
      cannot both be inside `materialize/4`. Provision runs in the Elixir runner
      BEFORE `site-deploy.sh` takes its per-slug `flock`, so this lock is the
      only thing serializing it.
    * **Fail-closed.** Any failure (missing template, unwritable sites dir, a
      failed rename) returns `{:error, {:provision_failed, reason}}`. The caller
      short-circuits exactly like an `open_port/1` failure: it NEVER opens the
      deploy Port, so a deploy whose source could not be materialized dies
      before it can run against nothing.

  ## The delete window (2026-08-05 search-capstone wedge)

  This module used to do `rm_rf!(src)` and THEN `rename(partial, src)`. On
  2026-08-05T21:01:45 that `rm_rf!` raised
  (`%File.Error{reason: :eexist, path: ".../search-capstone/src",
  action: "remove files and directories recursively from"}`) with two same-slug
  deploys in flight — AFTER the recursive delete had begun and BEFORE the
  rename. It left 22 of 66 template files on disk: `app/` survived while
  `components/`, `lib/`, `schemas/`, `scripts/`, `next.config.mjs` and the rest
  were gone, so the 29 `"@/"` imports in the surviving `app/` became 29
  "Module not found" build errors.

  The old moduledoc's atomicity promise ("a crash mid-copy dies in
  `src.partial`") was TRUE — and covered only the COPY window. The DELETE
  window had no protection at all. Worse, the marker survived (rewritten by the
  concurrent provision that succeeded) and its digest fingerprints the TEMPLATE,
  never `src` — so `provisioned_fresh?/4` returned true forever and
  `materialize/4` was never called again. One ~400ms race became 25
  deterministic failures with no path back.

  All three properties above exist because of that incident: the swap removes
  the delete window, the manifest check makes a mutilated tree self-heal instead
  of wedging, and the per-slug lock stops two provisions racing in the first
  place.
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

  # Written INSIDE the staged tree before the swap — its presence is the
  # idempotency guard.
  @marker ".bp-provisioned"

  # Sibling scratch paths. `.partial` stages the new tree; `.stale` holds the
  # OUTGOING tree between the two renames and is unlinked only once the new one
  # is live.
  @partial_suffix ".partial"
  @stale_suffix ".stale"

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

    # The freshness check and the materialize it guards are ONE critical
    # section: two same-slug deploys must never both decide "not fresh" and
    # both start swapping trees under each other.
    with_slug_lock(slug, fn ->
      {files, digest} = template_manifest(template_path)

      if provisioned_fresh?(src, template_key, digest, files) do
        :ok
      else
        materialize(src, template_path, template_key, digest)
      end
    end)
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

  @doc """
  The `:global` lock id that serializes provisioning of ONE slug.

  Provision runs in the Elixir runner BEFORE `site-deploy.sh` takes its per-slug
  `flock`, so nothing else serializes two same-slug deploys. Public so a caller
  (or a test) can observe/hold the same lock this module takes.
  """
  @spec lock_id(String.t()) :: {{module(), String.t()}, pid()}
  def lock_id(slug) when is_binary(slug), do: {{__MODULE__, slug}, self()}

  # Blocks until the slug's lock is free, runs `fun`, releases it — including if
  # `fun` raises (`:global.trans/2` unlocks in an `after`). `:aborted` is
  # `:global`'s "could not acquire", which is fail-closed like any other error.
  defp with_slug_lock(slug, fun) do
    case :global.trans(lock_id(slug), fun) do
      :aborted -> {:error, {:provision_failed, {:lock_aborted, slug}}}
      result -> result
    end
  end

  # ── materialize ───────────────────────────────────────────────────────────

  # Reachability: every path written here is `src` — `src_dir/1`, the configured
  # sites dir joined with a slug `DeployRequest` already validated against
  # `~r/\A[a-z0-9][a-z0-9-]{0,62}\z/` (deploy_request.ex:104), a pattern that
  # cannot express a dot or a slash — plus the module constants
  # `@partial_suffix`, `@stale_suffix` and `@marker`. The copy SOURCE is
  # `template_dir/1` over the closed `@templates` map. No caller-supplied path
  # component reaches any of these calls.
  # sobelow_skip ["Traversal.FileModule"]
  defp materialize(src, template, template_key, digest) do
    if File.dir?(template) do
      partial = src <> @partial_suffix
      stale = src <> @stale_suffix

      # Build the full copy in `src.partial` FIRST, marker included, so the
      # swap below is the single commit point. If anything here fails, `src` is
      # untouched — still the good prior source, or absent.
      File.rm_rf!(partial)
      File.rm_rf!(stale)
      File.mkdir_p!(Path.dirname(src))
      File.cp_r!(template, partial)
      File.write!(Path.join(partial, @marker), marker_body(template_key, digest))

      swap(src, partial, stale)
    else
      {:error, {:provision_failed, {:template_not_found, template}}}
    end
  end

  # The swap (2026-08-05 wedge): move the OUTGOING tree aside, rename the new
  # one into place, and only then unlink the outgoing one. `src` is never
  # deleted in place, so no failure — including a `rm_rf` that raises partway
  # through — can leave a half-populated `src` for BUILD to mistake for a real
  # checkout.
  defp swap(src, partial, stale) do
    case File.rename(src, stale) do
      # The live tree is now parked at `.stale`, intact.
      :ok -> commit(src, partial, stale, true)
      # First provision for this slug — nothing to move aside.
      {:error, :enoent} -> commit(src, partial, stale, false)
      {:error, reason} -> abort(partial, {:swap_aside_failed, reason})
    end
  end

  # Reachability: `src`, `partial` and `stale` are not derived here at all —
  # they arrive from `materialize/4`, which built all three from `src_dir/1`
  # (regex-validated slug, deploy_request.ex:104) and the `@partial_suffix` /
  # `@stale_suffix` constants. The `rm_rf` only ever unlinks the tree this
  # module itself parked at `<src>.stale` two lines earlier.
  # sobelow_skip ["Traversal.FileModule"]
  defp commit(src, partial, stale, moved_aside?) do
    case File.rename(partial, src) do
      :ok ->
        # Best-effort: the new tree is already live, so a failure to unlink the
        # outgoing one is litter, never a broken site. The next provision's
        # `rm_rf!(stale)` retries it.
        File.rm_rf(stale)
        :ok

      {:error, reason} ->
        # Put the outgoing tree back so `src` is the COMPLETE old source again.
        if moved_aside?, do: File.rename(stale, src)
        abort(partial, {:rename_failed, reason})
    end
  end

  # Reachability: `partial` is the staging tree this module created one call
  # earlier — `src_dir(slug) <> @partial_suffix`, with `slug` regex-validated at
  # deploy_request.ex:104 to a pattern with no dot and no slash in it. The only
  # caller-influenced value reaching `abort/2` is `reason`, which is returned,
  # never joined into a path.
  # sobelow_skip ["Traversal.FileModule"]
  defp abort(partial, reason) do
    File.rm_rf(partial)
    {:error, {:provision_failed, reason}}
  end

  # Freshness guard — PROVENANCE (the marker) *and* INTEGRITY (the tree).
  #
  # Provenance (search-template W1 live-proof fix): the marker records WHICH
  # template materialized this src and a content digest of that template tree.
  # A provision is a no-op ONLY when both still match — so a template update (or
  # a template SWITCH on an existing slug) re-materializes instead of silently
  # serving stale source forever (proven live: search-capstone kept building a
  # pre-.basepath tree until the src was hand-cleared). A legacy marker without
  # template=/digest= lines fails the match and re-materializes once — the safe
  # upgrade path. Build caches (node_modules) survive only unchanged-template
  # redeploys, which is exactly the boundary we want: same inputs, same cache.
  #
  # Integrity (2026-08-05 wedge): the digest fingerprints the TEMPLATE, never
  # `src` — a marker can be perfectly valid while the tree beneath it has been
  # mutilated, which is exactly how search-capstone wedged for 25 consecutive
  # deploys with no path back. So freshness ALSO requires every path of the
  # template manifest to still exist in `src`: a tree missing files
  # re-materializes even though the template digest is unchanged, and the wedge
  # self-heals on the next deploy.
  #
  # Integrity is PRESENCE, not content. `src` legitimately diverges from the
  # template in content (a build writes into it; `node_modules`/`.next` appear),
  # so re-hashing `src` would re-copy on every deploy and would mean walking a
  # `node_modules` tree on every provision. Presence of the manifest is one
  # `stat` per template file and catches the class that actually bit us: files
  # that VANISHED.
  # Reachability: the single read is `Path.join(src, @marker)` — `src_dir/1`
  # (regex-validated slug, deploy_request.ex:104: no dot, no slash) joined with
  # the `@marker` module constant. It is read-only, it never writes, and the
  # bytes it returns are parsed into a `template=`/`digest=` comparison, never
  # into a path.
  # sobelow_skip ["Traversal.FileModule"]
  defp provisioned_fresh?(src, template_key, digest, template_files) do
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

        fields["template"] == Atom.to_string(template_key) and fields["digest"] == digest and
          src_intact?(src, template_files)

      {:error, _} ->
        false
    end
  end

  # Every file the template materialized must still be on disk. `File.exists?`
  # follows symlinks, so a dangling link counts as missing — also a tree we
  # should not trust.
  defp src_intact?(src, template_files) do
    Enum.all?(template_files, &File.exists?(Path.join(src, &1)))
  end

  # The template's file manifest (relative, path-sorted) plus a sha256 over
  # every file's relative path + content — a pure function of the template
  # tree's bytes (never mtimes, which churn per checkout). ~40MB templates hash
  # in well under a second; the cost buys the no-op/rematerialize decision being
  # CONTENT-true, and the manifest it already walks is what `src_intact?/2`
  # compares `src` against.
  # Reachability: nothing from the request is on this path at all. `template` is
  # `template_dir/1` over the closed `@templates` map (a `Map.fetch!` on an atom
  # key, with a config override), and each `rel` is a filename this function's
  # own `tree_files/2` read back out of that same tree with `File.ls!` — a
  # directory listing, not user input. The reads are of the shipped starter we
  # are about to copy.
  # sobelow_skip ["Traversal.FileModule"]
  defp template_manifest(template) do
    case File.dir?(template) do
      false ->
        {[], "absent"}

      true ->
        files = template |> tree_files() |> Enum.sort()

        digest =
          files
          |> Enum.reduce(:crypto.hash_init(:sha256), fn rel, acc ->
            acc
            |> :crypto.hash_update(rel)
            |> :crypto.hash_update(File.read!(Path.join(template, rel)))
          end)
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {files, digest}
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
