defmodule Barkpark.Content.EnvelopeNilSchemaResiduePinTest do
  @moduledoc """
  RESIDUE PIN (arpss wave 3 → `arpss-envelope-schema-nil-residue-pin`), filed
  under the epic's SEAL-EACH-BYPASS doctrine: when a seal is a DECLARATION, pin
  the precondition that makes the declaration load-bearing — otherwise the next
  read surface silently re-opens the class by omitting it.

  THE CONTRACT, said once and loudly:

      Envelope.render(doc, nil, caller) applies NO per-field visibility
      redaction. NONE. Not for a nil caller, not for an explicitly anonymous
      one. `private: true`, `visibility: "private"`, `visibility: "owner_only"`
      and `readable_by` are SCHEMA declarations, and with no schema there is
      nothing to read them off. Every field the document stores is served.

  This is not a bug and this test does not ask for it to change (the row says a
  fail-closed default — nil schema ⇒ drop declared-PII classes, or refuse the
  render on an anon path — needs a RULING first, and none has been made). It is
  a SHARP EDGE, and the pin's whole job is to make a reviewer of a new read
  surface hit it.

  ## The seal this guards

  `arpss-author-email-seed-note` (PR #11809, 4252a5cb99) made the demo seed's
  `author.email` field `private: true`, and
  `test/barkpark/content/envelope_author_email_seal_test.exs` pins that an
  anonymous caller does not receive it. Every assertion in that file threads the
  real `author` schema into `render/3`. That seal therefore says nothing
  whatsoever about a caller who does NOT thread a schema — and this file is the
  other half: the same seeded author document, the same anonymous caller, a nil
  schema, and the email is served in full.

  Read the two files as one statement: THE SEAL IS THE SCHEMA ARGUMENT.

  ## The anon-reachable render sites that must keep threading a schema

  Derived on origin/main (95633e704) by `git grep -n "Envelope.render(" -- api/lib`
  plus the `render_many` / `render_many_by_type` shapes — NOT from the filing,
  whose four anchors ("query_controller.ex:77/:391, legacy :216, expand, search
  hit_envelope") are stale line numbers and an undercount. What actually exists,
  with the variable each site threads:

    * `barkpark_web/controllers/query_controller.ex` `index/2`
      — `Envelope.render_many(docs, schema, caller_context)`; `schema` from
      `fetch_schema(conn, type, dataset)`. `GET /v1/data/query/:dataset/:type`
      rides the `:api` pipeline (OptionalToken) ⇒ ANONYMOUS-REACHABLE.
    * `barkpark_web/controllers/query_controller.ex` `show_doc/5`
      — `[Envelope.render(doc, schema, caller_context)]`; same `fetch_schema`.
      `GET /v1/data/doc/:dataset/:type/:doc_id` ⇒ ANONYMOUS-REACHABLE.
    * `barkpark/content/expand.ex` `resolve/…`
      — `Envelope.render(doc, schema, caller_context)` for every EXPANDED
      reference. Reached from both query_controller reads above (`?expand=`),
      so it inherits their anonymous reachability. The referenced doc's own
      schema, not the parent's.
    * `barkpark/search/hit_envelope.ex` (two sites, `cards/…` and
      `documents/7`) — `Envelope.render_many_by_type(resolver, ctx)` /
      `(schema_resolver, caller_context)`. `render_many_by_type/3` exists
      PRECISELY because these multi-type result sets used to render with
      `schema == nil`; it is the fix for this residue on the search surface.
      `GET /v1/data/search/:dataset`, the federated route and the live search
      channel ⇒ ANONYMOUS-REACHABLE.
    * `barkpark_web/controllers/legacy_controller.ex` `render_legacy_doc/3`
      — `doc |> Envelope.render(schema, caller_context)`.
      `GET /documents/:type[/:id]` ⇒ ANONYMOUS-REACHABLE.
    * `barkpark_web/controllers/share_link_controller.ex` `show/2`
      — `Envelope.render(doc, schema, CallerContext.from_conn(conn))`.
      `GET …/s/:token` is bearer-less by design ⇒ ANONYMOUS-REACHABLE.
    * `barkpark/media/delivery/asset_response.ex` `asset_payload/3`
      — `Envelope.render(doc, asset_schema(doc, dataset), caller_context(conn))`
      for the embedded `mediaAsset` document on the shared media read routes.
    * `barkpark/content/papers.ex` `read/…`
      — `Envelope.render(paper, schema, CallerContext.anonymous())` for the
      public paper reader.

  NOT anonymous: `history_controller.ex` and `listen_controller.ex` (both
  `:require_token`), `export.ex`, `mutations.ex`, `papers.ex`'s writeback
  resolver and `papers/value_writeback.ex` (writer paths), and the three
  `content/broadcast.ex` sites, which pass the `:internal` sentinel.

  ⚠ THREE of the anon sites above resolve their schema through a `case … do
  {:ok, s} -> s; _ -> nil end` FALLBACK — `share_link_controller.ex:282`,
  `asset_response.ex`'s `asset_schema/2`, and `papers.ex`'s `read` — so a
  missing / unresolvable schema row puts a LIVE anonymous route on exactly the
  no-redaction path this file pins. The contract is not hypothetical there; it
  is one failed `Content.get_schema/3` away.

  ## Relationship to the sibling tripwire

  `envelope_internal_sentinel_test.exs` scans the same call sites for the OTHER
  bypass — a caller argument of `:internal`. This file scans the SCHEMA
  argument for a literal `nil`. Different argument, different bypass, no
  overlap; the census arm below deliberately allowlists the same three
  `broadcast.ex` sites that file sanctions, because they are the one place both
  bypasses legitimately meet.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.{CallerContext, Document, Envelope, SchemaDefinition}
  alias Barkpark.Repo

  setup do
    # capture_io: the seed profile narrates via IO.puts — keep test output clean
    ExUnit.CaptureIO.capture_io(fn ->
      scope = Barkpark.Seeds.Shared.ensure_default_scope()
      Barkpark.Seeds.Demo.seed(scope)
    end)

    schema = Repo.get_by!(SchemaDefinition, name: "author")
    doc = Repo.get_by!(Document, doc_id: "a1", type: "author")
    %{schema: schema, doc: doc}
  end

  test "the fixture is the sealed one — the stored author schema declares private: true on email",
       %{schema: schema} do
    # Non-vacuity guard for everything below: if the seal ever drops out of the
    # seed, the positive control would go green for the WRONG reason (nothing
    # to redact), and this pin would quietly stop meaning anything.
    email_field = Enum.find(schema.fields, &(&1["name"] == "email"))
    assert email_field, "seeded author schema lost its email field"
    assert email_field["private"] == true
  end

  test "THE CONTRACT: schema = nil serves the sealed email to an ANONYMOUS caller",
       %{doc: doc} do
    env = Envelope.render(doc, nil, CallerContext.anonymous())

    assert env["email"] == "knut@sanity.io",
           "schema=nil must apply NO redaction — if this went green-to-red, the " <>
             "nil-schema contract CHANGED and every comment in this file is now wrong"
  end

  test "…and to a nil caller too — nil schema outranks the fail-closed nil caller",
       %{doc: doc} do
    # `render/3`'s nil-CALLER clause is fail-closed (it substitutes the anonymous
    # principal). That clamp is real, and it is still powerless here: it decides
    # WHO is asking, while the schema decides WHAT is declared private. With
    # nothing declared, the most restrictive principal in the system still sees
    # every field.
    env = Envelope.render(doc, nil, nil)
    assert env["email"] == "knut@sanity.io"
  end

  test "POSITIVE CONTROL: the SAME doc + the SAME anonymous caller + the real schema drops it",
       %{doc: doc, schema: schema} do
    # Without this arm the contract pin above could go green because redaction
    # is broken EVERYWHERE. One document, one caller, one variable changed.
    env = Envelope.render(doc, schema, CallerContext.anonymous())

    refute Map.has_key?(env, "email"),
           "redaction is broken with a schema THREADED — the nil-schema pin above is vacuous"
  end

  test "SCOPE LINE: the schema argument changes EXACTLY the email key, nothing else",
       %{doc: doc, schema: schema} do
    # Bounds the residue. The nil-schema render is not a different envelope, a
    # different projection or a different perspective — it is the sealed
    # envelope plus the declared-private field, byte for byte.
    env_nil = Envelope.render(doc, nil, CallerContext.anonymous())
    env_sealed = Envelope.render(doc, schema, CallerContext.anonymous())

    assert Map.delete(env_nil, "email") == env_sealed
    assert Map.has_key?(env_nil, "email")
    refute Map.has_key?(env_sealed, "email")
  end

  # ── static census: no lib/ site renders with a LITERAL nil schema ──────────
  #
  # Complements (never duplicates) envelope_internal_sentinel_test.exs: that
  # file keys on the CALLER argument being `:internal`; this one keys on the
  # SCHEMA argument being a literal `nil`. A dynamic nil (a `case` fallback
  # binding `schema = nil`) is INVISIBLE to this scan — three anon sites do
  # exactly that, and they are named in the moduledoc instead. That is the
  # honest limit of a static arm, stated rather than papered over.

  @lib_dir Path.expand("../../../lib", __DIR__)
  @definition_site "barkpark/content/envelope.ex"
  @render_funs [:render, :render_many, :render_many_by_type]

  # The sanctioned literal-nil-schema sites: the immediate broadcast, the
  # deferred flush and the stored mutation_events snapshot. All three also pass
  # the `:internal` caller sentinel and are re-redacted per subscriber
  # downstream — the same set envelope_internal_sentinel_test.exs sanctions.
  @expected_nil_schema %{"barkpark/content/broadcast.ex" => 3}

  test "every Envelope render site in lib/ threads a schema, except the sanctioned Broadcast three" do
    sites = render_sites()

    # NON-VACUITY: the scan must actually be seeing the call graph. 18 sites on
    # origin/main 95633e704; a floor of 14 survives ordinary churn but not a
    # scanner that silently matches nothing.
    assert length(sites) >= 14,
           "the scanner found only #{length(sites)} Envelope render sites in lib/ — it is blind"

    nil_schema = for {file, line, :nil_schema} <- sites, do: {file, line}

    assert Enum.frequencies_by(nil_schema, &elem(&1, 0)) == @expected_nil_schema, """
    The set of LITERAL nil-schema Envelope renders in lib/ changed.

    A nil schema disables per-field visibility ENTIRELY — `private`,
    `visibility: "private"`, `owner_only` and `readable_by` all stop being read,
    so the field they guard is served to whoever asked. Found:

    #{inspect(nil_schema, pretty: true)}

    If the new site is on a writer/internal path whose output is re-redacted
    downstream, extend @expected_nil_schema AND say in the call site's own
    comment who re-redacts it. If it is on a READ path, thread the type's
    schema instead — `render_many_by_type/3` exists for the multi-type case.
    """
  end

  test "no source under lib/barkpark_web/ renders with a literal nil schema" do
    web =
      for {file, line, :nil_schema} <- render_sites(),
          file =~ ~r{^barkpark_web/},
          do: {file, line}

    # NON-VACUITY: the web layer must be in the scan's field of view at all.
    web_total = Enum.count(render_sites(), fn {file, _, _} -> file =~ ~r{^barkpark_web/} end)

    assert web_total >= 5,
           "only #{web_total} web-layer render sites seen — the scan is not reaching lib/barkpark_web/"

    assert web == [], """
    A web-layer read surface now renders with a literal nil schema:

    #{inspect(web, pretty: true)}

    The web layer serves REQUESTERS, and several of its routes are anonymous
    (see this file's moduledoc for the list). A nil schema there means every
    declared-private field on the type — the seeded author `email` among them —
    is served to whoever asked. Resolve the type's schema and thread it.
    """
  end

  defp render_sites do
    for file <- Path.wildcard(Path.join(@lib_dir, "**/*.ex")),
        (rel = Path.relative_to(file, @lib_dir)) != @definition_site,
        {:ok, ast} <- [Code.string_to_quoted(File.read!(file))],
        {line, kind} <- envelope_render_calls(unpipe_all(ast)) do
      {rel, line, kind}
    end
    |> Enum.sort()
  end

  # Rewrite `a |> Envelope.render(b, c)` into `Envelope.render(a, b, c)` so the
  # SCHEMA is always argument index 1 regardless of the call shape written.
  defp unpipe_all(ast) do
    Macro.prewalk(ast, fn
      {:|>, _meta, [lhs, rhs]} = node ->
        try do
          Macro.pipe(lhs, rhs, 0)
        rescue
          _ -> node
        end

      node ->
        node
    end)
  end

  defp envelope_render_calls(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case envelope_call(node) do
          {_fun, meta, args} ->
            kind = if Enum.at(args, 1) == nil, do: :nil_schema, else: :threaded
            {node, [{Keyword.get(meta, :line, 0), kind} | acc]}

          nil ->
            {node, acc}
        end
      end)

    Enum.reverse(acc)
  end

  # ONLY the alias-qualified shape (`Envelope.render(…)` / `Content.Envelope.render(…)`).
  # A bare `render(conn, …)` is Phoenix's, and matching it would drown the scan.
  defp envelope_call({{:., _, [{:__aliases__, _, mod}, fun]}, meta, args})
       when is_list(args) do
    if fun in @render_funs and List.last(mod) == :Envelope and length(args) >= 2,
      do: {fun, meta, args},
      else: nil
  end

  defp envelope_call(_), do: nil
end
