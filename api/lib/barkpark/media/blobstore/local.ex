defmodule Barkpark.Media.Blobstore.Local do
  @moduledoc """
  The on-disk backend — a verbatim extraction of the pre-blobstore file ops
  (`File.mkdir_p` + `File.cp` / `File.write` under `Media.upload_dir/0`).

  Every operation is NON-raising and collapses unexpected file errors to
  `{:error, :storage_unavailable}`, preserving `Media.upload/3`'s contract
  that a disk fault (ENOSPC / EACCES / read-only mount) surfaces as an
  enveloped 503, never a bare 500.

  Both write verbs answer with a `t:Barkpark.Media.Blobstore.receipt/0`: the
  bytes RECEIVED plus a post-condition `stat_blob/1` read of what the store
  actually holds. Here the disk IS the store — there is no write-through cache
  to bypass — so `File.stat` on the real path is the honest read, not the trap
  it would be under the S3 backend.
  """

  @behaviour Barkpark.Media.Blobstore

  alias Barkpark.Media
  alias Barkpark.Media.Blobstore

  # ── PATH PROVENANCE ────────────────────────────────────────────────────────
  #
  # The TWO-CLAUSE reachability verdict behind every
  # `sobelow_skip ["Traversal.FileModule"]` in this module. Both clauses hold
  # and neither alone is the answer, so neither may be dropped: clause (1)
  # says the upload path cannot traverse, clause (2) says the import path CAN
  # and names what actually stops it. Shortening this to "server-generated,
  # safe" would be false.
  #
  # CITED BY SYMBOL, NOT BY LINE. This block used to carry twelve `file.ex:NNN`
  # pins and NINE of them had drifted — `import_member/3` by 342 lines, and the
  # router pin onto a comment reading "a `:media`-shared scope is public here",
  # the OPPOSITE of the premise it was cited for. A reviewer
  # re-validating these skips was walked to the wrong place. Symbols survive
  # insertion and a `Module.func/arity` in backticks is a claim
  # tooling/doc-truth actually verifies; a line number is verified by nobody.
  # Grep the name. Every claim below was re-derived against origin/main and
  # every one still HOLDS — only the pointers had rotted.
  #
  # (1) Every UPLOAD path is server-generated. `Media.upload/3` is the ONLY
  #     changeset writer of `media_files.path` in `lib/` — `MediaFile.changeset/2`
  #     has exactly one call site in `lib/`, inside `Media.upload/3`, fed the
  #     attrs map built there — and the value it writes is
  #     `"<yyyy>/<mm>/" <> unique_filename(original_name)`. `unique_filename/1`
  #     runs the client filename through `Path.basename/2`, which discards every
  #     directory component, then slugs the base with `~r/[^a-z0-9-]/`, so no
  #     separator survives; the only `.` that can is the one `Path.extname/1`
  #     re-appends as the extension:
  #     `"../../../etc/passwd"` becomes `"passwd-<hex>"` and `".."` becomes
  #     `"-<hex>."`. A client-supplied filename cannot steer these calls out of
  #     `Media.upload_dir/0`.
  #
  # (2) The IMPORT path is admin-gated, and clause (1) does NOT cover it.
  #     `import_member/3` in `Barkpark.Tenancy.WorkspaceBundle` COPYs the
  #     manifest-named tables verbatim — `media_files` is a copy-strategy bundle
  #     member, pinned in `@pinned_e1` in
  #     `Barkpark.Tenancy.WorkspaceBundle.Catalog` — straight into the real table
  #     with `COPY … FROM STDIN`, past `MediaFile.changeset/2` entirely. So an
  #     admin bundle CAN plant `../../..` in `media_files.path`, and that value
  #     reaches `Media.file_path/1` and the calls below. What bounds it is
  #     AUTHORIZATION, not sanitisation: the sole route is
  #     `BarkparkWeb.WorkspaceController`'s `:import` action, mounted in the
  #     router's `scope "/api"` that pipes through `[:api, :require_admin]`, and
  #     the mint allowlists for the app/session/support tiers cap at
  #     `public-read`/`read`/`write`/`chat` (`@allowed_permissions` in
  #     `BarkparkWeb.TokenController`, `@app_token_permissions` in
  #     `BarkparkWeb.AppTokenController`, the inline `["read", "write"]` in
  #     `BarkparkWeb.PlaygroundController`, `@support_permissions` in
  #     `BarkparkWeb.FleetSupportTokenController`, `@claude_session_permissions`
  #     in `Barkpark.Auth`).
  #
  #     The one HTTP-reachable personal-access-token mint —
  #     `BarkparkWeb.AuthController.create_token/2`, the sole caller of
  #     `Auth.create_personal_access_token/3` outside `Barkpark.Auth` — no
  #     longer hardcodes `["read"]`; #14245 made it DERIVE the tier from the
  #     caller's OWN `Tenancy.Membership` role via
  #     `Auth.max_pat_permissions_for_role/1`. A member still resolves to
  #     `@pat_allowed_member_permissions` (`["read"]`); an owner/admin resolves
  #     to `@pat_allowed_admin_permissions`, which is `["read", "write",
  #     "admin"]` today. So "no HTTP mint issues `admin`" is NOT the bound here
  #     any more — narrowing that self-mint is the open PR #14933's subject, not
  #     this module's. What still bounds THIS clause is unchanged and
  #     sufficient: `:require_admin` demands the `admin` permission, so a caller
  #     who can plant that path already holds admin standing and can already
  #     restore an arbitrary workspace.

  @impl true
  # `full_path` is `Media.file_path/1` — see PATH PROVENANCE above. `source_path`
  # is the `%Plug.Upload{path: …}` temp file chosen by Plug — `Media.upload/3` is
  # the only caller of this verb — never client text.
  # sobelow_skip ["Traversal.FileModule"]
  def put_file(relative_path, source_path, _opts) do
    full_path = Media.file_path(relative_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.cp(source_path, full_path),
         {:ok, %File.Stat{size: received}} <- File.stat(source_path) do
      Blobstore.receipt(received, :stat, stat_blob(relative_path))
    else
      # cp may have written a partial file before failing → best-effort cleanup
      # so no orphan blob survives (moved here verbatim from Media.upload/3).
      {:error, _reason} ->
        _ = File.rm(full_path)
        {:error, :storage_unavailable}
    end
  end

  @impl true
  # `full_path` is `Media.file_path/1` — see PATH PROVENANCE above. This verb has
  # one additional producer that only NARROWS the verdict: `Media.put_blob/2`
  # (the HTTP `PUT /v1/media/blob/*path` edge) refuses anything
  # `Media.valid_blob_path?/1` rejects — a per-segment allowlist that
  # fails closed on `.`, `..`, a leading `/`, a trailing `/`, and any
  # backslash/null/space shape.
  # sobelow_skip ["Traversal.FileModule"]
  def put_bytes(relative_path, body, _opts) do
    full_path = Media.file_path(relative_path)

    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, body) do
      Blobstore.receipt(byte_size(body), :stat, stat_blob(relative_path))
    else
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  @impl true
  def stat_blob(relative_path) do
    case File.stat(Media.file_path(relative_path)) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, %{size: size}}
      # a directory (or a device/symlink target) at the blob path is not a blob
      {:ok, %File.Stat{}} -> {:error, :not_found}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  # `Media.file_path/1` — see PATH PROVENANCE above. This is the one verb reached
  # with a path read BACK off a `media_files` row — `Media.delete_file/2` passes
  # `file.path` to `Blobstore.delete/1` — so clause (2) is the operative clause
  # here, not clause (1).
  # sobelow_skip ["Traversal.FileModule"]
  def delete(relative_path) do
    _ = File.rm(Media.file_path(relative_path))
    :ok
  end

  @impl true
  def ensure_local(relative_path) do
    full_path = Media.file_path(relative_path)

    if File.regular?(full_path) do
      {:ok, full_path}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def serve_strategy(relative_path, _opts) do
    # The `File.regular?` probe is the HONEST missing-blob 404 the serve edge
    # relies on (a media_files row can outlive its blob after a bundle import)
    # — without it send_file's internal File.stat raises on :enoent → 500.
    case ensure_local(relative_path) do
      {:ok, full_path} -> {:file, full_path}
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
