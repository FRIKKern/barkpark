defmodule BarkparkCloud.AuditLabelCensusTest do
  @moduledoc """
  cch-w62-bl — a LABEL census over the audit register's verb vocabulary.

  Its sibling `audit_vocabulary_census_test.exs` asks whether a declared verb is
  PRODUCED. This file asks the other question, the one that file explicitly
  disclaims ("It says nothing about whether a produced action is LABELLED in the
  console"): does every verb an operator can be shown resolve to a SENTENCE, or
  is it named — individually, with a reason — as unlabelled on purpose?

  Three arms, and each one is the arm that would have caught a real regression:

    * ARM (a) DECLARED → LABELLED. Every verb in the closed
      `AuditEvent.actions/0` allowlist carries a non-nil `label` in
      `cloud/priv/audit-actions.json`, or is a key of `@unlabelled` below. A new
      verb appended with `label: null` and a plausible-sounding reason reds
      here, BY NAME. `audit_event.ex`'s compile-time raise already refuses a row
      with no `label` key and a null with no substantive reason — but nothing
      bounded the SET of nulls, so "unlabelled on purpose" could grow one row at
      a time forever. This is the bound.

    * ARM (b) LABELLED → DECLARED, over the SHIPPED artifact. Every key in the
      generated `ACTION_LABELS` region of `cloud/priv/static/app.js` must be a
      declared verb, and must carry the table's exact label. The Elixir side
      DERIVES `@actions` from the same table, so comparing the table to itself
      proves nothing; the region is the one mirror that can rot independently —
      a verb deleted from the table leaves its label in the shipped file until
      `node design/emit.mjs --write` runs, and until then the console states a
      sentence for a fact the plane can no longer record.

    * ARM (c) THE ALLOWLIST IS NOT STALE. Every `@unlabelled` key must still be
      declared AND must still be `label: null` in the table. Labelling a verb
      without deleting its excuse leaves a certified absence behind a present
      label — the shape `audit_vocabulary_census_test.exs` learned the hard way
      with `@producerless`.

  ## Limits, stated so nobody over-reads a green run

    * It proves a verb HAS a sentence, not that the sentence is TRUE of the act.
      Copy accuracy is a review judgment; this file is a coverage floor.
    * It reads the ACTION_LABELS region as TEXT. It does not execute app.js —
      `cloud/priv/static/__app.test.mjs` drives `humanAction` and
      `tlvEntryTitle` for that, and this arm is what makes the JS side's
      table-derived assertions non-circular from the Elixir gate's side.
    * Two console surfaces are out of scope by construction: the Overview
      3-item digest renders through `activityRow`, which reads only
      `e.metadata.name`, and `GET /v1/audit` is team-admin gated, so a plain
      member never sees these rows at all.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Accounts.AuditEvent

  @manifest Path.expand("../../priv/audit-actions.json", __DIR__)
  @app_js Path.expand("../../priv/static/app.js", __DIR__)

  @region_begin "/* BEGIN GENERATED: audit action labels"
  @region_end "/* END GENERATED: audit action labels */"

  # Floors. A broken extractor must RED, not report a clean tree.
  @declared_floor 50
  @labelled_floor 50

  # Declared verbs with NO console label. Named one by one, never a wildcard: a
  # THIRD unlabelled verb reds this census.
  #
  # Each value must name WHY, and the reason has to survive arm (c) — the verb
  # must still be declared and still be null in the table. An entry that a slice
  # has since labelled reds instead of rotting.
  @unlabelled %{
    "oauth.linked" =>
      "Copy is owned by another open row — cch-w53-bl-oauth-linked-needs-a-branch-reporting-return, " <>
        "the slice that made the verb producible at all. A slice that mints a verb owns its sentence; " <>
        "this census's row (cch-w62-bl) took the 31 verbs no open slice owned.",
    "email.verified" =>
      "No producer anywhere in cloud/lib — the one zero-producer verb in the vocabulary, excused with a " <>
        "machine-checked anchor/blocker pair in audit_vocabulary_census_test.exs's @producerless. " <>
        "A label would name a category the feed cannot show, because no row can ever carry the verb."
  }

  defp table do
    @manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("actions")
  end

  defp reason_codes do
    @manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("reason_codes") |> Map.keys()
  end

  # The SHIPPED ACTION_LABELS region, parsed as text. Comment lines are dropped
  # first so a slug quoted in prose cannot masquerade as an entry.
  defp shipped_labels do
    src = File.read!(@app_js)
    [_, rest] = String.split(src, @region_begin, parts: 2)
    [body, _] = String.split(rest, @region_end, parts: 2)

    body
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("//")))
    |> Enum.join("\n")
    |> then(&Regex.scan(~r/"([a-z0-9_.]+)":\s*"((?:[^"\\]|\\.)*)"/, &1))
    |> Map.new(fn [_, verb, label] -> {verb, unescape(label)} end)
  end

  defp unescape(s), do: s |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

  test "the extractors are not vacuous" do
    declared = AuditEvent.actions()

    assert length(declared) >= @declared_floor,
           "the declared vocabulary shrank to #{length(declared)} verbs — every arm below has gone vacuous"

    assert map_size(shipped_labels()) >= @labelled_floor,
           "the shipped ACTION_LABELS region parsed to #{map_size(shipped_labels())} entries — " <>
             "the extractor broke, or the region emptied"

    assert map_size(@unlabelled) > 0,
           "arm (a)'s allowlist is empty — either every verb is labelled (delete this arm) or the map lost its rows"
  end

  test "arm (a): every declared verb is labelled, or named in @unlabelled with a reason" do
    labelled = for %{"verb" => v, "label" => l} <- table(), l != nil, into: MapSet.new(), do: v
    excused = MapSet.new(Map.keys(@unlabelled))

    unaccounted =
      AuditEvent.actions()
      |> Enum.reject(&(MapSet.member?(labelled, &1) or MapSet.member?(excused, &1)))

    assert unaccounted == [],
           "these declared verbs render as their raw dotted slug in the operator's sentence slot and " <>
             "nothing excuses them: #{inspect(unaccounted)}. Give each a `label` in " <>
             "cloud/priv/audit-actions.json (then `node design/emit.mjs --write`), or add it to " <>
             "@unlabelled here with a reason naming who owns the copy."

    for {verb, reason} <- @unlabelled do
      assert String.length(reason) > 60,
             "#{verb}'s @unlabelled reason is a stub — an excused absence must say why, or a bare name would be honester"
    end
  end

  test "arm (b): every label the SHIPPED app.js serves belongs to a declared verb, with the table's exact text" do
    declared = MapSet.new(AuditEvent.actions())
    by_verb = Map.new(table(), fn %{"verb" => v} = r -> {v, r["label"]} end)

    for {verb, label} <- shipped_labels() do
      assert MapSet.member?(declared, verb),
             "cloud/priv/static/app.js's ACTION_LABELS serves #{inspect(verb)} => #{inspect(label)}, " <>
               "but no such verb is declared — the console states a sentence for a fact the plane can no " <>
               "longer record. Re-run `node design/emit.mjs --write`."

      assert by_verb[verb] == label,
             "#{verb}: the shipped region says #{inspect(label)}, the table says #{inspect(by_verb[verb])} — " <>
               "the mirror rotted. Re-run `node design/emit.mjs --write`."
    end

    # And the other direction of the SAME mirror: a labelled verb the region
    # dropped renders as a raw slug in prod while the table claims copy exists.
    missing =
      for %{"verb" => v, "label" => l} <- table(),
          l != nil,
          not Map.has_key?(shipped_labels(), v),
          do: v

    assert missing == [],
           "these verbs are labelled in the table but absent from the shipped ACTION_LABELS region: " <>
             "#{inspect(missing)}. Re-run `node design/emit.mjs --write`."
  end

  test "arm (c): no @unlabelled entry is stale" do
    declared = MapSet.new(AuditEvent.actions())
    by_verb = Map.new(table(), fn %{"verb" => v} = r -> {v, r} end)
    codes = reason_codes()

    for {verb, _reason} <- @unlabelled do
      assert MapSet.member?(declared, verb),
             "@unlabelled excuses #{inspect(verb)}, which is no longer a declared verb — delete the entry"

      row = by_verb[verb]

      assert row["label"] == nil,
             "@unlabelled still excuses #{inspect(verb)}, but the table now labels it " <>
               "#{inspect(row["label"])} — delete the excuse"

      assert row["reason_code"] in codes,
             "#{verb}'s reason_code #{inspect(row["reason_code"])} is not one of the table's declared " <>
               "reason_codes #{inspect(codes)}"
    end
  end
end
