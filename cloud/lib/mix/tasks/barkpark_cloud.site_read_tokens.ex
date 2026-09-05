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
      mix barkpark_cloud.site_read_tokens --census         # EVERY live token, with its ceiling
      mix barkpark_cloud.site_read_tokens BOX --census     # ditto, one instance
      mix barkpark_cloud.site_read_tokens BOX --revoke ID  # revoke ONE orphan

  `BOX` is an instance id (UUID) or slug. `ID` is the box-side token id printed
  by the audit.

  ## The two questions, and why `--census` is the second one

  The default audit answers "which credentials outlived their SITE?". `--census`
  answers "which credentials outlived THEMSELVES?" — every live `site-read-*`
  row, with the lifetime ceiling
  `Registry.site_read_token_max_age_days/0` draws and whether it has been
  crossed. The orphan set is a strict subset: a token for a site that still
  exists can be far past its ceiling and never show up in the audit above.

  A ceiling that cannot be COMPUTED (the box returns neither `expires_at` nor a
  readable `inserted_at`) prints `unknown`, and those rows are counted
  separately. "I could not tell" is not "it is inside the ceiling".

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

    case OptionParser.parse(args, strict: [revoke: :string, census: :boolean]) do
      {opts, [box_ref], []} ->
        cond do
          token_id = Keyword.get(opts, :revoke) -> revoke(box_ref, token_id)
          Keyword.get(opts, :census, false) -> census([box_ref])
          true -> audit([box_ref])
        end

      {[], [], []} ->
        audit(:fleet)

      {[census: true], [], []} ->
        census(:fleet)

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
  The LIFETIME census (task-b3e3ec0f433b217d): every live `site-read-*`
  credential on one instance or the whole fleet, each carrying the ceiling
  `Registry.site_read_token_max_age_days/0` draws and whether it is past it.

  Same `{barkpark, {:ok, rows} | {:error, reason}}` shape as `audit_boxes/1`, and
  for the same reason: an unreadable instance must stay distinguishable from a
  clean one. Public so a test can drive it without spawning a Mix process.
  """
  @spec census_boxes(:fleet | [String.t()]) :: [{struct(), {:ok, [map()]} | {:error, atom()}}]
  def census_boxes(:fleet) do
    Registry.all_barkparks() |> Enum.map(&{&1, Registry.site_read_token_census(&1)})
  end

  def census_boxes(refs) when is_list(refs) do
    for ref <- refs, bp = resolve_barkpark(ref) do
      {bp, Registry.site_read_token_census(bp)}
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

  # ── the LIFETIME census ─────────────────────────────────────────────────────

  defp census(scope) do
    case census_boxes(scope) do
      [] -> Mix.shell().info("No instances to audit.")
      results -> Enum.each(census_lines(results), fn line -> Mix.shell().info(line) end)
    end
  end

  @doc """
  Render a `census_boxes/1` result as the lines the task prints — pure, so the
  OUTPUT an operator reads is what a test can assert on. The printer only
  forwards these to `Mix.shell/0`; nothing is formatted twice.
  """
  @spec census_lines([{struct(), {:ok, [map()]} | {:error, atom()}}]) :: [String.t()]
  def census_lines(results) when is_list(results) do
    Enum.flat_map(results, &census_box_lines/1) ++ census_summary_lines(results)
  end

  defp census_box_lines({bp, {:ok, []}}), do: ["#{bp.slug}: no live site-read tokens"]

  defp census_box_lines({bp, {:ok, rows}}) do
    expired = Enum.count(rows, & &1.expired?)

    header =
      "#{bp.slug}: #{length(rows)} live site-read token(s), #{expired} past the " <>
        "#{Registry.site_read_token_max_age_days()}-day ceiling"

    [header | Enum.map(rows, &census_row_lines/1)]
  end

  defp census_box_lines({bp, {:error, :no_scope}}),
    do: ["#{bp.slug}: no workspace/project scope to look under — not audited"]

  defp census_box_lines({bp, {:error, :unreadable}}),
    do: [
      "#{bp.slug}: UNREADABLE — its token inventory could not be read. This is NOT a clean " <>
        "bill of health; its tokens' ceilings are unknown, not met."
    ]

  defp census_row_lines(r) do
    "  #{r.label}#{if r.expired?, do: "   *** EXPIRED ***", else: ""}\n" <>
      "    id            #{r.id}\n" <>
      "    scope         #{r.workspace}/#{r.project}\n" <>
      "    site          #{r.site_slug}#{if r.orphan?, do: " (ORPHAN — no such site)", else: ""}\n" <>
      "    minted        #{r.inserted_at || "unknown"}\n" <>
      "    expires       #{expiry_line(r)}\n" <>
      "    last used     #{r.last_used_at || "never"}"
  end

  # The denominator rides with every count, exactly as `summarise/1` does it: an
  # audit that prints "0 expired" while two boxes were unreadable and three
  # tokens carry no computable ceiling is the same false green the orphan sweep
  # refuses to print.
  defp census_summary_lines(results) do
    rows = for {_bp, {:ok, rs}} <- results, r <- rs, do: r
    unreadable = for {bp, {:error, :unreadable}} <- results, do: bp.slug
    expired = Enum.filter(rows, & &1.expired?)
    unknown = Enum.filter(rows, &(&1.expiry_source == :unknown))

    total =
      "\n#{length(rows)} live site-read token(s) across #{length(results)} instance(s); " <>
        "#{length(expired)} past the #{Registry.site_read_token_max_age_days()}-day ceiling"

    [total] ++
      unknown_line(unknown) ++ unreadable_line(unreadable) ++ rotate_line(expired)
  end

  defp unknown_line([]), do: []

  defp unknown_line(unknown),
    do: [
      "#{length(unknown)} token(s) carry NO computable ceiling (no expires_at, no readable " <>
        "inserted_at) — they are not in that count, and they are not known to be inside it."
    ]

  defp unreadable_line([]), do: []

  defp unreadable_line(slugs),
    do: [
      "#{length(slugs)} instance(s) could not be read (#{Enum.join(slugs, ", ")}) — their " <>
        "tokens are UNKNOWN and are not in that count."
    ]

  defp rotate_line([]), do: []

  defp rotate_line(_expired),
    do: [
      "Nothing was rotated. Rotating a live credential is an owner decision: " <>
        "`Registry.rotate_site_read_token/1` mints the replacement BEFORE it revokes the " <>
        "incumbent, so the site never goes dark."
    ]

  # ONE rendering of a ceiling, used by both the orphan report and the census, so
  # the two can never print a different verdict for the same row. A row whose
  # ceiling could not be computed says so — it never renders as blank (which
  # reads as "none") or as a date nobody derived.
  defp expiry_line(%{expiry_source: :unknown}),
    do: "unknown (no expires_at and no readable inserted_at)"

  defp expiry_line(%{expires_at: %DateTime{} = at, expiry_source: source, expired?: expired?}),
    do:
      "#{DateTime.to_iso8601(at)} (#{source})#{if expired?, do: " — PAST THE CEILING", else: ""}"

  # A row from a caller that predates the census fields carries no ceiling at
  # all; say that rather than crash an operator's audit.
  defp expiry_line(_), do: "unknown"

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
          "    expires       #{expiry_line(o)}\n" <>
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
