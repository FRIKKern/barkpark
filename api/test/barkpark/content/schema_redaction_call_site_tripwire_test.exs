defmodule Barkpark.Content.SchemaRedactionCallSiteTripwireTest do
  @moduledoc """
  THE TRIPWIRE for `@canonical capability:schema-resolution-for-redaction`
  (task-3d433b8f497738f9, criterion 4).

  ## What this guards

  `Content.get_schema/3` with a binary `:workspace_id` cannot see a GLOBALLY
  declared schema (`workspace_id: nil`), and `Envelope` is fail-OPEN on a nil
  schema — so a NEW single-step scoped lookup feeding an Envelope redaction
  function silently re-opens the leak that
  `Content.Schema.get_schema_for_redaction/3` was written to close. Fourteen
  sites drifted into that shape before anyone noticed. This test is the notice.

  ## The mechanism — SET EQUALITY on `file:function`, not on line numbers

  Two source-level censuses, each asserted as an exact set:

    1. every `Content.get_schema(` / `Barkpark.Content.get_schema(` /
       `Schema.get_schema(` call site under `api/lib` must appear in
       `@raw_get_schema_sites` with a one-line reason why it does NOT need the
       fallback (it is unscoped, or its result never reaches Envelope);
    2. every `Content.Schema.get_schema_for_redaction(` call site must appear in
       `@redaction_resolver_sites` — the resolvers that DO feed Envelope.

  Both are `MapSet` equalities, so:

    * a new single-step scoped site fails BY NAME ("unlisted raw
      Content.get_schema/3 call sites"), and a reviewer must either route it
      through the helper or add it here with a reason — the allowlist cannot
      grow by accident;
    * a REMOVED site also fails, so the list cannot rot into a description of
      code that no longer exists.

  Keys are `relative/path.ex:enclosing_function` — never line numbers, which
  drift on every unrelated insertion and would make this a maintenance tax
  instead of a guard.

  ## The proximity heuristic, and its honest limits

  Alongside the set equality, each call site is classified by whether a ±40-line
  window around it mentions an Envelope redaction entry point (`Envelope.render`
  / `redact` / `field_readable?` / `render_many_by_type`) or a known resolver
  name (`schema_resolver`, `HitEnvelope`). That is a PROXIMITY signal, not a
  dataflow analysis: it over-reports (a neighbouring function's `Envelope.` call
  lands in the window) and it cannot see a schema handed across module
  boundaries. It is asserted anyway — every raw site whose window trips it must
  carry `envelope_adjacent: true` plus a reason saying why the schema does not
  in fact reach a redaction boundary. Exactly one does today
  (`expand.ex:load_schemas`, whose schema map drives reference-FIELD detection
  while the neighbouring `Envelope.render/3` uses `ref_schema/3`'s result).

  The set equality is the real gate; the heuristic is the reading aid that makes
  a reviewer look at the right thing.

  ## The one gap this closes by assertion

  `content/schema.ex` calls its own `get_schema/3` unqualified, which no
  qualified-call regex can see. Rather than parse the module, the last test
  asserts that module never references `Envelope.` at all — so no in-module
  private helper there can be feeding a redaction boundary.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("lib")

  # Qualified calls to the RAW, single-step lookup.
  @raw_call ~r/(?<![\w.])(?:Barkpark\.)?(?:Content|Schema)\.get_schema\(/

  # Calls to the shared two-step helper.
  @redaction_call ~r/(?<![\w.])(?:Barkpark\.)?Content\.Schema\.get_schema_for_redaction\(/

  @envelope_window ~r/Envelope\.(render|redact|field_readable\?|render_many_by_type|render_many)\b|schema_resolver|HitEnvelope/

  @def_line ~r/^\s*(?:defp|def)\s+([a-z_][A-Za-z0-9_?!]*)/

  # ── Census 1: raw Content.get_schema/2,3 — every one of these must be either
  #    UNSCOPED (it already resolves the global row) or provably not feeding an
  #    Envelope redaction boundary. `envelope_adjacent: true` marks the sites the
  #    proximity heuristic flags, each with the reason it is nonetheless safe.
  @raw_get_schema_sites %{
    # -- unscoped (2-arity, or an explicit `[]`): scope_to_workspace_or_global/3
    #    with a nil workspace is the deliberate global read, so the global row
    #    already resolves and no fallback is needed.
    "barkpark/media.ex:patch_asset_metadata" => "unscoped 2-arity existence check",
    "barkpark/tenancy.ex:pulled_schema_row" => "unscoped 2-arity provenance guard",
    "barkpark/tasks/board.ex:field_visibility_gate" => "explicit [] — unscoped global read",
    "barkpark/tasks/query.ex:row_field_visibility_gate" => "explicit [] — unscoped global read",
    "barkpark/plugins/tasks.ex:task_schema_present?" => "unscoped 2-arity presence probe",
    "barkpark/plugins/tickets.ex:ticket_schema_present?" => "unscoped 2-arity presence probe",
    "barkpark/plugins/tasks/web/board_live.ex:peek_schema" =>
      "explicit [] — unscoped global read",
    "barkpark/content/edges.ex:disconnect_one_source" => "unscoped 2-arity, edge write path",
    "barkpark/content/encryption.ex:encrypt_marked" => "unscoped 2-arity, WRITE-path cipher",
    "barkpark/content/papers.ex:synthesize_blocks" => "unscoped 2-arity, block synthesis",
    "barkpark/content/writer.ex:validate_document" => "unscoped 2-arity, write validation",
    "barkpark/content/writer.ex:apply_initial_values" => "unscoped 2-arity, write scaffold",
    "barkpark/content/writer.ex:scaffold_or_initial_values" => "unscoped 2-arity, write scaffold",
    "barkpark_web/studio/pane_builder.ex:walk_path" => "unscoped 2-arity, Studio pane layout",
    "barkpark_web/live/studio/studio_live/handlers/secondary.ex:select_secondary" =>
      "unscoped 2-arity, Studio pane selection",

    # -- scoped, but the result never reaches an Envelope redaction function.
    "barkpark/content/expand.ex:load_schemas" =>
      {:envelope_adjacent,
       "reference-FIELD detection only (drives ref_fields_for/2); the neighbouring " <>
         "Envelope.render/3 redacts with ref_schema/3's result, which DOES use the helper"},
    "barkpark/search/query_pipeline.ex:resolve_schema" =>
      "feeds the fail-CLOSED Highlighter, not Envelope",
    "barkpark_web/controllers/schema_controller.ex:show" =>
      "serves the schema itself; a miss is a 404, not a render",
    "mix/tasks/barkpark.workspace.provision_schemas.ex:provision_one" =>
      "mix task copying schema rows between scopes",
    "barkpark/content.ex:get_schema" => "the facade delegate — this IS the raw lookup",
    "barkpark/content.ex:owner_scoped?" => "reads the owner_scoped flag, not field visibility"
  }

  # ── Census 2: the redaction resolvers. Every Envelope render/redact site
  #    resolves its schema HERE, through the one two-step helper.
  @redaction_resolver_sites MapSet.new([
                              # the five pre-existing two-step sites, now delegating
                              "barkpark/content/papers.ex:value_schema",
                              "barkpark/content/papers/value_writeback.ex:target_schema",
                              "barkpark/content/expand.ex:ref_schema",
                              "barkpark_web/controllers/query_controller.ex:fetch_schema",
                              "barkpark_web/controllers/legacy_controller.ex:fetch_schema",
                              # the fourteen that had no fallback at all
                              "barkpark/content/papers.ex:reader_source",
                              "barkpark_web/live/sheets_reader_live.ex:seal",
                              "barkpark/media/delivery/asset_response.ex:asset_schema",
                              "barkpark_web/controllers/share_link_controller.ex:serve",
                              "barkpark_web/controllers/search_controller.ex:schema_resolver",
                              "barkpark_web/controllers/federated_search_controller.ex:schema_resolver",
                              "barkpark_web/channels/search_channel.ex:schema_resolver",
                              "barkpark_web/controllers/history_controller.ex:show",
                              "barkpark_web/controllers/history_controller.ex:restore",
                              "barkpark_web/controllers/listen_controller.ex:fetch_schema",
                              "barkpark_web/controllers/tasks_controller.ex:seal_ctx",
                              "barkpark/content/export.ex:fetch_schema",
                              "barkpark/content/mutations.ex:echo_schema",
                              "barkpark/tasks/query.ex:load_task_schema"
                            ])

  setup_all do
    assert File.dir?(@lib), "expected an api/lib directory at #{@lib} (run mix test from api/)"
    :ok
  end

  test "every raw Content.get_schema/2,3 call site is listed with a reason" do
    found = scan(@raw_call)
    listed = @raw_get_schema_sites |> Map.keys() |> MapSet.new()
    actual = found |> Enum.map(& &1.key) |> MapSet.new()

    # Non-vacuity: an empty scan would green both directions below.
    assert MapSet.size(actual) > 15,
           "the scanner found #{MapSet.size(actual)} raw call sites — it is not reading api/lib"

    unlisted = MapSet.difference(actual, listed)

    assert MapSet.size(unlisted) == 0, """
    UNLISTED raw `Content.get_schema/2,3` call sites:

    #{unlisted |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")}

    A tenant-SCOPED raw lookup whose result reaches Envelope.render/redact/
    field_readable?/render_many_by_type is the leak this tripwire exists for:
    route it through `Content.Schema.get_schema_for_redaction/3` instead.
    If the site is genuinely unscoped or genuinely not a redaction site, add it
    to @raw_get_schema_sites WITH the one-line reason.
    """

    stale = MapSet.difference(listed, actual)

    assert MapSet.size(stale) == 0, """
    STALE entries in @raw_get_schema_sites (no such call site any more):

    #{stale |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")}

    Delete them — the allowlist must describe today's code, not yesterday's.
    """
  end

  test "every raw site the Envelope-proximity heuristic flags carries an explicit reason" do
    flagged =
      @raw_call
      |> scan()
      |> Enum.filter(& &1.envelope_adjacent?)
      |> Enum.map(& &1.key)
      |> MapSet.new()

    excused =
      @raw_get_schema_sites
      |> Enum.filter(&match?({_, {:envelope_adjacent, _}}, &1))
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    # Non-vacuity in BOTH directions: the heuristic must actually fire on
    # something (else a new leaking site would never be flagged), and every
    # excuse must correspond to a site the heuristic really flags (else the
    # excuses are decoration).
    assert MapSet.size(flagged) > 0,
           "the Envelope-proximity heuristic flagged nothing — it has gone blind"

    assert MapSet.equal?(flagged, excused), """
    Envelope-proximity mismatch.

    Flagged by the heuristic but not excused in @raw_get_schema_sites:
    #{MapSet.difference(flagged, excused) |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")}

    Excused but no longer flagged (delete the {:envelope_adjacent, _} marker):
    #{MapSet.difference(excused, flagged) |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")}
    """
  end

  test "the redaction resolvers are exactly the sites that call the shared helper" do
    actual = @redaction_call |> scan() |> Enum.map(& &1.key) |> MapSet.new()

    assert MapSet.equal?(actual, @redaction_resolver_sites), """
    The set of `Content.Schema.get_schema_for_redaction/3` call sites changed.

    New (add to @redaction_resolver_sites):
    #{MapSet.difference(actual, @redaction_resolver_sites) |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")}

    Gone — a render site that STOPPED using the helper is exactly the
    regression this row fixed; restore it or remove it from the list:
    #{MapSet.difference(@redaction_resolver_sites, actual) |> Enum.sort() |> Enum.map_join("\n", &"  - #{&1}")}
    """
  end

  test "the helper's own module never touches Envelope, so no unqualified in-module call can leak" do
    source = File.read!(Path.join(@lib, "barkpark/content/schema.ex"))

    assert source =~ "def get_schema_for_redaction(",
           "the canonical helper is gone from Barkpark.Content.Schema"

    assert source =~ "@canonical capability:schema-resolution-for-redaction",
           "the canonical marker is gone from the helper"

    refute source =~ ~r/Envelope\./,
           "Barkpark.Content.Schema now references Envelope — its unqualified " <>
             "get_schema/3 calls are invisible to this tripwire's regex, so the " <>
             "in-module gap this test closed by assertion is open again"
  end

  # ── scanner ───────────────────────────────────────────────────────────────

  defp scan(pattern) do
    @lib
    |> ex_files()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, @lib)
      lines = path |> File.read!() |> String.split("\n")

      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} -> Regex.match?(pattern, line) end)
      |> Enum.map(fn {_line, i} ->
        %{
          key: "#{rel}:#{enclosing_function(lines, i)}",
          envelope_adjacent?: Regex.match?(@envelope_window, window(lines, i))
        }
      end)
    end)
    |> Enum.uniq_by(& &1.key)
  end

  defp ex_files(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp enclosing_function(lines, index) do
    lines
    |> Enum.slice(0..index)
    |> Enum.reverse()
    |> Enum.find_value("<module body>", fn line ->
      case Regex.run(@def_line, line) do
        [_, name] -> name
        _ -> nil
      end
    end)
  end

  defp window(lines, index) do
    lines
    |> Enum.slice(max(index - 40, 0)..(index + 40))
    |> Enum.join("\n")
  end
end
