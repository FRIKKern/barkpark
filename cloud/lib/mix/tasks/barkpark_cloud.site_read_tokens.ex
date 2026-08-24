defmodule Mix.Tasks.BarkparkCloud.SiteReadTokens do
  @moduledoc """
  Find — and, one at a time, revoke — ORPHAN `site-read-*` credentials: live
  public-read tokens on an instance whose site no longer exists.

  ## Why this exists as well as the fix

  `Registry.delete_site/1` now revokes a site's read token as part of the delete,
  so no NEW orphan is created. That does nothing for the ones already on the
  boxes. Measured on guerrilla 2026-07-28: 18 live `site-read-*` rows against 12
  sites — six of them credentials for sites that had been deleted, every one of
  them a never-expiring read grant into a live dataset. A fix that only helps
  future deletions leaves those six live forever, because nothing on the box
  expires a `public-read` token and nothing in this repo ever listed them.

  ## Usage

      mix barkpark_cloud.site_read_tokens                  # audit the whole fleet
      mix barkpark_cloud.site_read_tokens BOX              # audit one instance
      mix barkpark_cloud.site_read_tokens BOX --revoke ID  # revoke ONE orphan

  `BOX` is an instance id (UUID) or slug. `ID` is the box-side token id printed
  by the audit.

  ## Rails

    * The audit is READ-ONLY. It never revokes anything, and revoking is not a
      flag on the fleet sweep — you must name one box and one token id.
    * `--revoke` RE-DERIVES the orphan set at revoke time and refuses any id that
      is not in it. A token belonging to a site that still exists cannot be
      killed with this tool even by typing its id, and neither can an arbitrary
      workspace credential.
    * A box whose token inventory cannot be read is reported as UNREADABLE, never
      as "no orphans" — "I could not look" is not "there are none".

  Revoking a live credential is an owner decision. Audit first, read the list,
  then revoke the rows you have decided about — one command per row, on purpose.
  """
  @shortdoc "Audit (and revoke, one at a time) orphan site-read-* tokens on the fleet"

  use Mix.Task

  alias BarkparkCloud.Registry

  @impl Mix.Task
  def run(args) do
    # Boot the app so the Repo (and the instance HTTP seam) is live — every
    # data-touching task does this.
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: [revoke: :string]) do
      {opts, [box_ref], []} ->
        case Keyword.get(opts, :revoke) do
          nil -> audit([box_ref])
          token_id -> revoke(box_ref, token_id)
        end

      {[], [], []} ->
        audit(:fleet)

      {opts, [], []} when opts != [] ->
        Mix.shell().error(
          "--revoke needs an instance: mix barkpark_cloud.site_read_tokens BOX --revoke ID"
        )

        exit({:shutdown, 1})

      _ ->
        Mix.shell().error(
          "Usage: mix barkpark_cloud.site_read_tokens [BOX] [--revoke TOKEN_ID]   (BOX = instance id | slug)"
        )

        exit({:shutdown, 1})
    end
  end

  @doc """
  The orphan set for one instance, or for the whole fleet.

  Returns a list of `{barkpark, {:ok, orphans} | {:error, reason}}` — the errors
  are CARRIED, not dropped, so a caller can tell an instance with no orphans from
  one whose inventory could not be read. Public so a test can drive it without
  spawning a Mix process (the `grant_forever_for/1` precedent).
  """
  @spec audit_boxes(:fleet | [String.t()]) :: [{struct(), {:ok, [map()]} | {:error, atom()}}]
  def audit_boxes(:fleet) do
    Registry.all_barkparks() |> Enum.map(&{&1, Registry.orphan_site_read_tokens(&1)})
  end

  def audit_boxes(refs) when is_list(refs) do
    for ref <- refs, bp = resolve_barkpark(ref) do
      {bp, Registry.orphan_site_read_tokens(bp)}
    end
  end

  @doc """
  Revoke ONE orphan on `box_ref` by its box-side `token_id`.

  Re-derives the orphan set first and refuses an id that is not in it — that
  guard is the whole safety property of this task, so it lives here rather than
  at the call site: a live site's credential must not be killable by typo.
  """
  @spec revoke_orphan(String.t(), String.t()) ::
          :ok
          | {:error,
             :barkpark_not_found | :not_an_orphan | :unreadable | :no_scope | :revoke_failed}
  def revoke_orphan(box_ref, token_id) when is_binary(box_ref) and is_binary(token_id) do
    with %{} = bp <- resolve_barkpark(box_ref) || {:error, :barkpark_not_found},
         {:ok, orphans} <- Registry.orphan_site_read_tokens(bp),
         %{} = orphan <- Enum.find(orphans, &(&1.id == token_id)) || {:error, :not_an_orphan} do
      case Registry.revoke_workspace_token(
             bp,
             orphan.workspace,
             orphan.project,
             orphan.id,
             orphan.label
           ) do
        :ok -> :ok
        :error -> {:error, :revoke_failed}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── output ──────────────────────────────────────────────────────────────────

  defp audit(scope) do
    results = audit_boxes(scope)

    if results == [] do
      Mix.shell().info("No instances to audit.")
    else
      Enum.each(results, &report/1)
      summarise(results)
    end
  end

  defp report({bp, {:ok, []}}), do: Mix.shell().info("#{bp.slug}: no orphan site-read tokens")

  defp report({bp, {:ok, orphans}}) do
    Mix.shell().info("#{bp.slug}: #{length(orphans)} ORPHAN site-read token(s)")

    Enum.each(orphans, fn o ->
      Mix.shell().info(
        "  #{o.label}\n" <>
          "    id            #{o.id}\n" <>
          "    scope         #{o.workspace}/#{o.project}\n" <>
          "    deleted site  #{o.site_slug}\n" <>
          "    minted        #{o.inserted_at || "unknown"}\n" <>
          "    last used     #{o.last_used_at || "never"}\n" <>
          "    revoke with   mix barkpark_cloud.site_read_tokens #{bp.slug} --revoke #{o.id}"
      )
    end)
  end

  defp report({bp, {:error, :no_scope}}),
    do: Mix.shell().info("#{bp.slug}: no workspace/project scope to look under — not audited")

  defp report({bp, {:error, :unreadable}}),
    do:
      Mix.shell().error(
        "#{bp.slug}: UNREADABLE — its token inventory could not be read. This is NOT a clean bill " <>
          "of health; orphans here are unknown, not absent."
      )

  # The denominator is stated with the count. An audit that prints "0 orphans"
  # while three boxes were unreadable is the same false green this whole row is
  # about, so the unreadable count rides alongside.
  defp summarise(results) do
    orphans = for {_bp, {:ok, os}} <- results, o <- os, do: o
    unreadable = for {bp, {:error, :unreadable}} <- results, do: bp.slug

    Mix.shell().info(
      "\n#{length(orphans)} orphan site-read token(s) across #{length(results)} instance(s)"
    )

    if unreadable != [] do
      Mix.shell().error(
        "#{length(unreadable)} instance(s) could not be read (#{Enum.join(unreadable, ", ")}) — " <>
          "their orphans are UNKNOWN and are not in that count."
      )
    end

    if orphans != [] do
      Mix.shell().info(
        "Nothing was revoked. Revoking a live credential is an owner decision: revoke each row " <>
          "you have decided about with --revoke <id>."
      )
    end
  end

  defp revoke(box_ref, token_id) do
    case revoke_orphan(box_ref, token_id) do
      :ok ->
        Mix.shell().info("Revoked #{token_id} on #{box_ref}.")

      {:error, :barkpark_not_found} ->
        Mix.shell().error("No instance matches #{inspect(box_ref)} (id or slug).")
        exit({:shutdown, 1})

      {:error, :not_an_orphan} ->
        Mix.shell().error(
          "#{token_id} is not in #{box_ref}'s orphan set — it belongs to a site that still " <>
            "exists, is already revoked, or is not a site-read credential at all. Refused."
        )

        exit({:shutdown, 1})

      {:error, reason} when reason in [:unreadable, :no_scope] ->
        Mix.shell().error(
          "#{box_ref}'s orphan set could not be derived (#{reason}), so this revoke cannot be " <>
            "proven safe. Refused."
        )

        exit({:shutdown, 1})

      {:error, :revoke_failed} ->
        Mix.shell().error("#{box_ref} did not confirm the revoke of #{token_id}. Still live.")
        exit({:shutdown, 1})
    end
  end

  defp resolve_barkpark(ref) do
    Registry.get_barkpark(ref) || Enum.find(Registry.all_barkparks(), &(&1.slug == ref))
  end
end
