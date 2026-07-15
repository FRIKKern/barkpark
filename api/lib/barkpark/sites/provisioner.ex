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

  ## Which template (charter D63/D71)

  The template is selected by the request's `runtime_target` — the second axis
  of the deploy engine:

    * `:static` (default) → `templates/astro-starter` — the Astro symlink-swap
      site the box has always built;
    * `:node` → `templates/next-starter` — the Next.js node-slot SSR site.

  Everything BELOW the selection (partial-rename atomicity, the `.bp-provisioned`
  marker, self-heal, fail-closed) is framework-agnostic and identical for both.

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
    * **Marker-guarded no-op.** A `.bp-provisioned` marker is written INSIDE
      `src` ONLY after the rename. A redeploy of the same site sees the marker
      and returns `:ok` without touching disk — so a content-only redeploy does
      not clobber the site's `node_modules`/`dist` build cache.
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
  # Default template paths, relative to the repo root, keyed by runtime_target.
  # The BEAM's cwd is api/ under both `mix phx.server` and start.sh, so its
  # parent is the repo root — the same assumption DeployRunner.run_cd/0 makes
  # for `bash deploy/…`.
  @default_static_template_subpath "templates/astro-starter"
  @default_node_template_subpath "templates/next-starter"
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

  def provision(%DeployRequest{mode: :deploy, slug: slug, runtime_target: runtime_target}) do
    src = src_dir(slug)

    if provisioned?(src) do
      :ok
    else
      materialize(src, template_dir(runtime_target))
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

  defp materialize(src, template) do
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
            File.write!(Path.join(src, @marker), marker_body())
            :ok

          {:error, reason} ->
            File.rm_rf!(partial)
            {:error, {:provision_failed, {:rename_failed, reason}}}
        end
    end
  end

  defp provisioned?(src), do: File.regular?(Path.join(src, @marker))

  defp marker_body do
    "provisioned-at=#{DateTime.utc_now() |> DateTime.to_iso8601()}\n"
  end

  # ── config resolution ─────────────────────────────────────────────────────

  defp sites_dir, do: Keyword.get(config(), :sites_dir) || @default_sites_dir

  # Template selection by runtime_target (charter D63/D71). Each target has its
  # own overridable config key so a test can point either at a tmp stand-in; the
  # legacy `:template_dir` key remains the STATIC override (backward-compatible).
  defp template_dir(:node),
    do:
      Keyword.get(config(), :node_template_dir) ||
        default_template_dir(@default_node_template_subpath)

  defp template_dir(_static),
    do:
      Keyword.get(config(), :template_dir) ||
        default_template_dir(@default_static_template_subpath)

  defp default_template_dir(subpath),
    do: Path.join(Path.dirname(File.cwd!()), subpath)
end
