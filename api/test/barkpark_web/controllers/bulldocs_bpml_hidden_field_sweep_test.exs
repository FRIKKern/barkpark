defmodule BarkparkWeb.BulldocsBpmlHiddenFieldSweepTest do
  @moduledoc """
  Every field a reader is shown, made private alone: an unedited push of the
  pull keeps the stored Paper byte for byte, and a pull that refuses is
  refused by the push with the same error.

  The corpus is one Paper per block kind the BPML printer spells, read off
  the printer's own `block/2` clauses; each holds that kind's golden block
  (`test/support/fixtures/pd-parity`) behind an anchor paragraph whose text
  carries marks, a link and inline code. A kind with no golden, or whose
  golden does not print as BPML, uses the block written here instead
  (`@written`); a printer kind that still does not print fails the sweep,
  unless it is listed in `@kind_limits` with its reason.

  The fields are every key at every position of the reader's answer for
  those Papers with nothing hidden, nested ones included (inline nodes,
  section children, table cells), read off the answer itself. Each is made
  private through the `paper` schema's nested declaration of its path, and
  each row first shows that the reader's answer changed, so a field the
  declaration missed fails rather than passes. A position the schema refuses
  to declare fails too, unless it is listed in `@limits` with its reason.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, LabelFixtures, Tenancy}
  alias Barkpark.Content.{CallerContext, Envelope}
  alias Barkpark.PortableDoc.Bpml.Printer

  @ds "production"
  @token "barkpark-test-ingest-token"
  @golden_dir Path.expand("../../support/fixtures/pd-parity", __DIR__)

  @anchor %{
    "id" => "anchor",
    "type" => "paragraph",
    "content" => [
      %{"type" => "text", "value" => "Anchor "},
      %{"type" => "text", "value" => "bold", "marks" => ["strong"]},
      %{
        "type" => "link",
        "href" => "https://example.com/",
        "children" => [%{"type" => "text", "value" => "a link"}]
      },
      %{"type" => "code", "value" => "x = 1"}
    ]
  }

  # Positions the `paper` schema cannot declare, each with its reason. Any
  # other position the schema refuses fails the sweep, and so does a listed
  # one that now declares.
  @limits %{}

  # Printer kinds no Paper of which pulls, each with its reason. Any other
  # kind without a carrying Paper fails the sweep, and so does a listed one
  # that now pulls.
  @kind_limits %{}

  # Printer kinds whose golden is missing (quote) or does not print: the
  # paragraph golden carries map marks, and the card and section goldens hold
  # headings with no level.
  @card %{
    "type" => "card",
    "tone" => "info",
    "slots" => %{
      "title" => [%{"type" => "heading", "level" => 3, "text" => "Card title"}],
      "body" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Card body."}]}
      ]
    }
  }

  @written %{
    "quote" => %{
      "type" => "quote",
      "cite" => "A. Writer",
      "content" => [%{"type" => "text", "value" => "Quoted words."}]
    },
    "paragraph" => %{
      "type" => "paragraph",
      "align" => "center",
      "content" => [%{"type" => "text", "value" => "Leaning words.", "marks" => ["em"]}]
    },
    "card" => @card,
    "section" => %{
      "type" => "section",
      "layout" => %{"gap" => "md", "mode" => "grid", "tracks" => 2},
      "blocks" => [@card, Map.put(@card, "span", 2)]
    }
  }

  # ── the corpus ─────────────────────────────────────────────────────────

  # The block kinds the printer spells: the literal "type" of each `block/2`
  # clause, read from its compiled debug info.
  defp printer_kinds do
    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(Printer), [:debug_info])

    {:ok, %{definitions: definitions}} = backend.debug_info(:elixir_v1, Printer, data, [])

    for {{:block, 2}, _kind, _meta, clauses} <- definitions,
        {_meta, [pattern, _depth], _guards, _body} <- clauses,
        type = literal_type(pattern),
        is_binary(type),
        uniq: true,
        do: type
  end

  defp literal_type(pattern) do
    {_, type} =
      Macro.prewalk(pattern, nil, fn
        {"type", value} = node, nil when is_binary(value) -> {node, value}
        node, acc -> {node, acc}
      end)

    type
  end

  defp golden_blocks do
    for file <- File.ls!(@golden_dir), String.ends_with?(file, ".golden.json"), into: %{} do
      type = String.replace_suffix(file, ".golden.json", "")
      input = Map.fetch!(Jason.decode!(File.read!(Path.join(@golden_dir, file))), "input")
      {input["type"] || type, with_id(input, type)}
    end
  end

  defp with_id(block, type), do: Map.put_new(block, "id", "g-" <> type)

  # The golden when it pulls, else the block written here; nil when neither.
  defp printing_paper(kind, goldens) do
    candidates =
      [goldens[kind], @written[kind] && with_id(@written[kind], kind)]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(candidates, fn block ->
      slug = write!(kind, block)
      pulled = pull(slug)
      pulled.status == 200 && {slug, pulled}
    end)
  end

  defp scope,
    do: [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

  defp write!(kind, block) do
    slug = "bpml-sweep-#{kind}-#{System.unique_integer([:positive])}"

    attrs =
      LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "title" => "BPML " <> kind,
        "blocks" => [@anchor, block]
      })

    assert {:ok, _} = Content.upsert_paper(attrs)
    slug
  end

  # ── requests ───────────────────────────────────────────────────────────

  # One rate bucket per request, so the sweep never meets the limiter.
  defp conn do
    scoped_conn()
    |> Plug.Conn.put_private(
      :barkpark_rate_limit_scope,
      "bpml-sweep-#{System.unique_integer([:positive])}"
    )
  end

  defp pull(slug) do
    Process.put(:sweep_requests, Process.get(:sweep_requests, 0) + 1)
    get(conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
  end

  defp sync(slug, bpml, rev) do
    Process.put(:sweep_requests, Process.get(:sweep_requests, 0) + 1)

    conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp error(resp) do
    case Jason.decode(resp.resp_body || "") do
      {:ok, %{"error" => %{} = error}} -> Map.take(error, ["code", "message", "hint"])
      _ -> nil
    end
  end

  defp unchanged?(resp), do: resp.status == 200 and error(resp) == nil and unchanged_body?(resp)
  defp unchanged_body?(resp), do: Jason.decode!(resp.resp_body)["unchanged"] == true

  # ── the reader's answer ────────────────────────────────────────────────

  defp stored(slug) do
    slug |> Content.get_paper() |> Map.take([:content, :title, :rev, :updated_at])
  end

  defp shown(slug) do
    paper = Content.get_paper(slug)
    schema = Content.Papers.reader_schema(paper, "paper", @ds, [])
    Envelope.render(paper, schema, CallerContext.anonymous())
  end

  # Every key at every position: a list's items sit under "*".
  defp paths(%{} = map, prefix) do
    Enum.flat_map(map, fn {key, value} -> [prefix ++ [key] | paths(value, prefix ++ [key])] end)
  end

  defp paths(list, prefix) when is_list(list),
    do: Enum.flat_map(list, &paths(&1, prefix ++ ["*"]))

  defp paths(_leaf, _prefix), do: []

  defp user_paths(answer) do
    answer
    |> Map.reject(fn {key, _} -> String.starts_with?(key, "_") end)
    |> paths([])
  end

  # ── the declaration ────────────────────────────────────────────────────

  # `path` made private: a nested declaration of exactly that position.
  defp field([key]), do: %{"name" => key, "type" => "string", "private" => true}
  defp field([key, "*" | rest]), do: %{"name" => key, "type" => "array", "of" => item(rest)}
  defp field([key | rest]), do: %{"name" => key, "type" => "object", "fields" => [field(rest)]}

  # A list's items: a list again (an `of` map, read as the item itself), or
  # maps (the member-list form).
  defp item(["*" | rest]), do: %{"type" => "array", "of" => item(rest)}
  defp item(rest), do: [%{"type" => "object", "fields" => [field(rest)]}]

  defp declare(fields) do
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
      @ds,
      scope()
    )
  end

  defp title_field, do: %{"name" => "title", "type" => "string"}
  defp hide(path), do: declare(Enum.uniq_by([field(path), title_field()], & &1["name"]))

  # ── one row ────────────────────────────────────────────────────────────

  defp check(path, base) do
    before = stored(base.slug)
    answer = shown(base.slug)
    pulled = pull(base.slug)
    bpml = if pulled.status == 200, do: pulled.resp_body, else: base.bpml
    pushed = sync(base.slug, bpml, base.rev)
    wrote? = stored(base.slug) != before
    fail = &{:fail, path, base.kind, &1}

    cond do
      answer == base.answer -> fail.(:the_answer_did_not_change)
      wrote? -> fail.({:the_push_wrote, pushed.status})
      pulled.status == 200 and unchanged?(pushed) -> :kept
      pulled.status == 200 -> fail.({:push, pushed.status, pushed.resp_body})
      pulled.status == 422 and error(pushed) == error(pulled) -> {:refused, error(pulled)["code"]}
      true -> fail.({:pull, pulled.status, error(pulled), :push, pushed.status, error(pushed)})
    end
  end

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "every field the reader is shown, hidden alone, keeps an unedited push from writing" do
    kinds = Enum.sort(printer_kinds())
    goldens = golden_blocks()
    assert length(kinds) > 10, "the printer's block clauses read as #{inspect(kinds)}"
    missing = Enum.reject(kinds, &(Map.has_key?(goldens, &1) or Map.has_key?(@written, &1)))
    assert missing == [], "printer kinds with no block to write: #{inspect(missing)}"

    assert {:ok, _} = declare([title_field()])

    # Nothing hidden: each Paper pulls, and its unedited push writes nothing.
    {bases, unprintable} =
      kinds
      |> Enum.map(fn kind -> {kind, printing_paper(kind, goldens)} end)
      |> Enum.reduce({[], []}, fn
        {kind, nil}, {bases, unprintable} ->
          {bases, [kind | unprintable]}

        {kind, {slug, pulled}}, {bases, unprintable} ->
          [rev] = get_resp_header(pulled, "x-paper-rev")
          before = stored(slug)
          pushed = sync(slug, pulled.resp_body, rev)

          assert unchanged?(pushed),
                 "#{kind}, nothing hidden: #{pushed.status} #{pushed.resp_body}"

          assert stored(slug) == before, "#{kind}, nothing hidden: the push wrote"
          base = %{kind: kind, slug: slug, bpml: pulled.resp_body, rev: rev, answer: shown(slug)}
          {[base | bases], unprintable}
      end)

    no_carrier = unprintable -- Map.keys(@kind_limits)
    assert no_carrier == [], "printer kinds with no Paper that pulls: #{inspect(no_carrier)}"

    assert Map.keys(@kind_limits) -- unprintable == [], "kind limits that now pull: remove them"

    # The same count two ways: the printer's own clauses, read again, against
    # the distinct kinds of the Papers whose pull answered 200.
    printable = length(printer_kinds()) - map_size(@kind_limits)
    carried = bases |> Enum.map(& &1.kind) |> Enum.uniq() |> length()

    assert printable > 0 and carried == printable,
           "#{carried} printer kinds have a Paper that pulled; the printer spells #{printable}"

    [first | _] = bases = Enum.reverse(bases)

    # The first Paper carries every position outside its golden block; each
    # Paper carries its golden block's.
    rows =
      [{first, user_paths(first.answer)}]
      |> Kernel.++(
        for base <- bases,
            do: {base, paths(Enum.at(base.answer["blocks"], 1), ["blocks", "*"])}
      )
      |> Enum.flat_map(fn {base, paths} -> for path <- Enum.uniq(paths), do: {path, base} end)
      |> Enum.group_by(fn {path, _} -> path end, fn {_, base} -> base end)
      |> Map.new(fn {path, carriers} -> {path, Enum.uniq_by(carriers, & &1.slug)} end)

    for essential <- [["blocks", "*", "id"], ["blocks", "*", "content", "*", "value"]],
        do: assert(Map.has_key?(rows, essential), "no row for #{inspect(essential)}")

    results =
      for {path, carriers} <- Enum.sort(rows) do
        case hide(path) do
          {:ok, _} -> {path, Enum.map(carriers, &check(path, &1))}
          {:error, why} -> {path, {:not_declared, why}}
        end
      end

    undeclared = for {path, {:not_declared, _}} <- results, do: path
    outcomes = for {_path, list} <- results, is_list(list), outcome <- list, do: outcome
    failures = for {:fail, _, _, _} = failure <- outcomes, do: failure
    kept = Enum.count(outcomes, &(&1 == :kept))
    refused = Enum.count(outcomes, &match?({:refused, _}, &1))

    IO.puts(
      "BPML hidden-field sweep: #{length(kinds)} printer kinds, #{length(bases)} Papers " <>
        "(not printed: #{inspect(unprintable)}), #{map_size(rows)} fields, " <>
        "#{length(outcomes)} field x Paper rows (#{kept} kept, #{refused} refused), " <>
        "#{length(undeclared)} not declarable: #{inspect(undeclared)}; " <>
        "#{Process.get(:sweep_requests)} requests"
    )

    assert failures == [], Enum.map_join(failures, "\n", &inspect(&1, limit: 40))

    assert undeclared -- Map.keys(@limits) == [],
           "positions the schema could not declare: #{inspect(undeclared -- Map.keys(@limits))}"

    assert Map.keys(@limits) -- undeclared == [], "limits that now declare: remove them"

    {_, id_row} = List.keyfind(results, ["blocks", "*", "id"], 0)
    assert id_row != [], "the id row has no Paper"
    assert Enum.all?(id_row, &(&1 == {:refused, "hidden_block_id"})), inspect(id_row)
  end
end
