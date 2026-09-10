defmodule Mix.Tasks.BarkparkCloud.ContentWebhooks do
  @moduledoc """
  Find — and reap — ORPHAN `site-autodeploy-*` webhooks: rows on a box whose site
  no longer exists.

  ## Why this exists as well as the fix

  `Registry.delete_site/1` deregisters a site's content-publish webhook, and
  `Registry.delete_barkpark/1` now does the same for every site an instance
  delete cascades away, so no NEW orphan is created through either door. That
  does nothing for the ones already on the boxes — and until this task, NOTHING
  could reach them. Two docstrings in `registry.ex` said the hourly reconciler
  would "find it by name"; it cannot. `reconcile_content_webhooks/1` enumerates
  `list_content_webhook_sites/1`, a query over the LIVE `sites` table, and issues
  only `:put`/`:post`. An orphan has no `sites` row — that is what makes it an
  orphan — so the sweep never looks at it, and could not delete it if it did.

  The cost of leaving one: every delivery 404s against a receiver that no longer
  resolves, and `api/lib/barkpark/webhooks.ex` documents the auto-disable latch as
  HALF-OPEN — a disabled row is re-probed ~24x/day, forever.

  ## Usage

      mix barkpark_cloud.content_webhooks                  # audit the whole fleet
      mix barkpark_cloud.content_webhooks BOX              # audit one instance
      mix barkpark_cloud.content_webhooks BOX --reap ID    # reap ONE orphan
      mix barkpark_cloud.content_webhooks BOX --reap-all   # reap every orphan on BOX

  `BOX` is an instance id (UUID) or slug. `ID` is the box-side webhook id printed
  by the audit.

  ## Rails

    * The audit is READ-ONLY. It deletes nothing, and reaping is not a flag on the
      fleet sweep — you must name one box.
    * `--reap` and `--reap-all` RE-DERIVE the orphan set at reap time and refuse
      any id that is not in it. A webhook belonging to a site that still exists
      cannot be deleted with this tool even by typing its id, and neither can a
      hand-made hook whose name is not `site-autodeploy-<uuid>`.
    * A box whose webhook inventory cannot be read is reported as UNREADABLE,
      never as "no orphans" — "I could not look" is not "there are none". A
      `--reap` against such a box is REFUSED, because the safety guard above is
      exactly the thing that could not be evaluated.

  `--reap-all` exists (and `mix barkpark_cloud.site_read_tokens` deliberately has
  no equivalent) because the two populations are not alike: an orphan webhook is a
  failing delivery to a receiver that is already gone, so deleting one destroys no
  capability. A live read token is an access grant, and killing it by mistake
  breaks a site's build — which is why that tool makes a human name every row.
  """
  @shortdoc "Audit (and reap) orphan site-autodeploy-* webhooks on the fleet"

  use Mix.Task

  alias BarkparkCloud.Registry

  @impl Mix.Task
  def run(args) do
    # Boot the app so the Repo (and the instance HTTP seam) is live.
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: [reap: :string, "reap-all": :boolean]) do
      {opts, [box_ref], []} ->
        cond do
          id = Keyword.get(opts, :reap) -> reap_one(box_ref, id)
          Keyword.get(opts, :"reap-all", false) -> reap_all(box_ref)
          true -> audit([box_ref])
        end

      {[], [], []} ->
        audit(:fleet)

      {opts, [], []} when opts != [] ->
        Mix.shell().error(
          "--reap/--reap-all needs an instance: mix barkpark_cloud.content_webhooks BOX --reap ID"
        )

        exit({:shutdown, 1})

      _ ->
        Mix.shell().error(
          "Usage: mix barkpark_cloud.content_webhooks [BOX] [--reap WEBHOOK_ID | --reap-all]" <>
            "   (BOX = instance id | slug)"
        )

        exit({:shutdown, 1})
    end
  end

  @doc """
  The orphan set for one instance, or for the whole fleet.

  Returns a list of `{barkpark, {:ok, orphans} | {:error, reason}}` — the errors
  are CARRIED, not dropped, so a caller can tell an instance with no orphans from
  one whose inventory could not be read. Public so a test can drive it without
  spawning a Mix process (the `SiteReadTokens.audit_boxes/1` precedent).
  """
  @spec audit_boxes(:fleet | [String.t()]) :: [{struct(), {:ok, [map()]} | {:error, atom()}}]
  def audit_boxes(:fleet) do
    Registry.all_barkparks() |> Enum.map(&{&1, Registry.orphan_content_webhooks(&1)})
  end

  def audit_boxes(refs) when is_list(refs) do
    for ref <- refs, bp = resolve_barkpark(ref) do
      {bp, Registry.orphan_content_webhooks(bp)}
    end
  end

  @doc """
  Reap ONE orphan on `box_ref` by its box-side webhook `id`.

  Re-derives the orphan set first and refuses an id that is not in it — that guard
  is the whole safety property of this task, so it lives here rather than at the
  call site: a live site's trigger must not be killable by typo.
  """
  @spec reap_orphan(String.t(), String.t()) ::
          :ok
          | {:error,
             :barkpark_not_found | :not_an_orphan | :unreadable | :no_dataset | :reap_failed}
  def reap_orphan(box_ref, id) when is_binary(box_ref) and is_binary(id) do
    with %{} = bp <- resolve_barkpark(box_ref) || {:error, :barkpark_not_found},
         {:ok, orphans} <- Registry.orphan_content_webhooks(bp),
         %{} = orphan <- Enum.find(orphans, &(&1.id == id)) || {:error, :not_an_orphan} do
      case Registry.delete_content_webhook(bp, orphan.dataset, orphan.id, orphan.name) do
        :ok -> :ok
        :error -> {:error, :reap_failed}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reap EVERY orphan on `box_ref` in one pass — one derivation of the orphan set,
  one `:delete` per row in it.

  Returns `{:ok, %{reaped: [id], failed: [id]}}`, or the same `{:error, reason}`
  `reap_orphan/2` returns when the set could not be derived at all. A box whose
  inventory is unreadable reaps NOTHING: the guard that decides what is safe to
  delete is precisely the read that failed.
  """
  @spec reap_all_orphans(String.t()) ::
          {:ok, %{reaped: [String.t()], failed: [String.t()]}}
          | {:error, :barkpark_not_found | :unreadable | :no_dataset}
  def reap_all_orphans(box_ref) when is_binary(box_ref) do
    with %{} = bp <- resolve_barkpark(box_ref) || {:error, :barkpark_not_found},
         {:ok, orphans} <- Registry.orphan_content_webhooks(bp) do
      {:ok,
       Enum.reduce(orphans, %{reaped: [], failed: []}, fn o, acc ->
         case Registry.delete_content_webhook(bp, o.dataset, o.id, o.name) do
           :ok -> Map.update!(acc, :reaped, &(&1 ++ [o.id]))
           :error -> Map.update!(acc, :failed, &(&1 ++ [o.id]))
         end
       end)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── output ──────────────────────────────────────────────────────────────────

  defp audit(scope) do
    case audit_boxes(scope) do
      [] ->
        Mix.shell().info("No instances to audit.")

      results ->
        Enum.each(audit_lines(results), fn line -> Mix.shell().info(line) end)
    end
  end

  @doc """
  Render an `audit_boxes/1` result as the lines the task prints — pure, so the
  OUTPUT an operator reads is what a test can assert on. The printer only forwards
  these to `Mix.shell/0`; nothing is formatted twice.
  """
  @spec audit_lines([{struct(), {:ok, [map()]} | {:error, atom()}}]) :: [String.t()]
  def audit_lines(results) when is_list(results) do
    Enum.flat_map(results, &box_lines/1) ++ summary_lines(results)
  end

  defp box_lines({bp, {:ok, []}}), do: ["#{bp.slug}: no orphan site-autodeploy webhooks"]

  defp box_lines({bp, {:ok, orphans}}) do
    header = "#{bp.slug}: #{length(orphans)} ORPHAN site-autodeploy webhook(s)"

    [header | Enum.map(orphans, &orphan_row_lines(bp, &1))]
  end

  defp box_lines({bp, {:error, :no_dataset}}),
    do: ["#{bp.slug}: no dataset to look under — not audited"]

  defp box_lines({bp, {:error, :unreadable}}),
    do: [
      "#{bp.slug}: UNREADABLE — its webhook inventory could not be read. This is NOT a clean " <>
        "bill of health; orphans here are unknown, not absent."
    ]

  defp orphan_row_lines(bp, o) do
    "  #{o.name}\n" <>
      "    id            #{o.id}\n" <>
      "    dataset       #{o.dataset}\n" <>
      "    deleted site  #{o.site_id}\n" <>
      "    delivers to   #{o.url || "unknown"}\n" <>
      "    active        #{inspect(o.active?)}\n" <>
      "    reap with     mix barkpark_cloud.content_webhooks #{bp.slug} --reap #{o.id}"
  end

  # The denominator rides with the count. An audit that prints "0 orphans" while
  # three boxes were unreadable is the same false green this whole row is about.
  defp summary_lines(results) do
    orphans = for {_bp, {:ok, os}} <- results, o <- os, do: o
    unreadable = for {bp, {:error, :unreadable}} <- results, do: bp.slug

    total =
      "\n#{length(orphans)} orphan site-autodeploy webhook(s) across #{length(results)} instance(s)"

    [total] ++ unreadable_line(unreadable) ++ reap_line(orphans)
  end

  defp unreadable_line([]), do: []

  defp unreadable_line(slugs),
    do: [
      "#{length(slugs)} instance(s) could not be read (#{Enum.join(slugs, ", ")}) — their " <>
        "orphans are UNKNOWN and are not in that count."
    ]

  defp reap_line([]), do: []

  defp reap_line(_orphans),
    do: [
      "Nothing was reaped. Reap the rows you have decided about with --reap <id>, or every " <>
        "orphan on one box with --reap-all."
    ]

  defp reap_one(box_ref, id) do
    case reap_orphan(box_ref, id) do
      :ok ->
        Mix.shell().info("Reaped #{id} on #{box_ref}.")

      {:error, reason} ->
        Mix.shell().error(reap_error_line(box_ref, id, reason))
        exit({:shutdown, 1})
    end
  end

  defp reap_all(box_ref) do
    case reap_all_orphans(box_ref) do
      {:ok, %{reaped: [], failed: []}} ->
        Mix.shell().info("#{box_ref}: no orphan site-autodeploy webhooks. Nothing to reap.")

      {:ok, %{reaped: reaped, failed: []}} ->
        Mix.shell().info(
          "Reaped #{length(reaped)} orphan(s) on #{box_ref}: #{Enum.join(reaped, ", ")}."
        )

      {:ok, %{reaped: reaped, failed: failed}} ->
        Mix.shell().error(
          "Reaped #{length(reaped)} orphan(s) on #{box_ref}; #{length(failed)} were NOT " <>
            "confirmed deleted (#{Enum.join(failed, ", ")}) and must be assumed still live."
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error(reap_error_line(box_ref, "the orphan set", reason))
        exit({:shutdown, 1})
    end
  end

  @doc """
  The sentence a refused reap prints — pure, so the REASON an operator reads is
  what a test can assert on.
  """
  @spec reap_error_line(String.t(), String.t(), atom()) :: String.t()
  def reap_error_line(box_ref, id, :barkpark_not_found),
    do: "No instance matches #{inspect(box_ref)} (id or slug). #{id} was not touched."

  def reap_error_line(box_ref, id, :not_an_orphan),
    do:
      "#{id} is not in #{box_ref}'s orphan set — it belongs to a site that still exists, is " <>
        "already gone, or is not a site-autodeploy webhook at all. Refused."

  def reap_error_line(box_ref, _id, reason) when reason in [:unreadable, :no_dataset],
    do:
      "#{box_ref}'s orphan set could not be derived (#{reason}), so this reap cannot be proven " <>
        "safe. Refused."

  def reap_error_line(box_ref, id, :reap_failed),
    do: "#{box_ref} did not confirm the delete of #{id}. Still live."

  defp resolve_barkpark(ref) do
    Registry.get_barkpark(ref) || Enum.find(Registry.all_barkparks(), &(&1.slug == ref))
  end
end
