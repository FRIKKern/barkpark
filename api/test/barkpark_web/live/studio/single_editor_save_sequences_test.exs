defmodule BarkparkWeb.Studio.SingleEditorSaveSequences.Refuse do
  @moduledoc false
  # Refuses `f` holding "FAIL"; `f` holding "NEEDS" or the stage "done" while
  # `summary` is empty.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    c = Map.get(doc, "content") || %{}
    f = if is_binary(c["f"]), do: c["f"], else: ""
    no_summary? = c["summary"] in [nil, ""]

    cond do
      String.contains?(f, "FAIL") -> {:halt, "f FAIL"}
      String.contains?(f, "NEEDS") and no_summary? -> {:halt, "needs summary"}
      c["stage"] == "done" and no_summary? -> {:halt, "needs summary"}
      true -> :ok
    end
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.SingleEditorSaveSequencesTest do
  @moduledoc """
  One editor, generated sequences of changes, against the real LiveView
  (#26396 reviews).

  Two reviews each found a sequence in which a value the person had typed
  away was drawn again and then saved: a refused value typed back, and a
  value that could not be saved because of a field on another tab, typed
  back after that field was filled. Each was fixed and the next one found by
  hand. This test walks the space instead.

  The type has two tabs. Tab one: `f`, `g`, `summary`, `stage` (a select).
  Tab two: `must` (required; the dataset enforces its schema) and `other`.
  A `before_save` hook refuses some values of `f` and `stage`. Half of the
  sequences start from a document that has no `must`, so every save of it is
  refused until tab two is filled.

  A step types a value into a field of the open tab, often the value it had
  at the start, or switches tab. The page is modelled as a browser: it posts
  the inputs of the open tab as the person has them, and after each post
  every input but the one typed in shows what the server draws.

  After every step:

    * STORED: a field's stored value moves only to what the person last
      typed there
    * DRAWN: each drawn input shows what the person last typed there, or the
      stored value when they typed nothing. The input just typed in is left
      out: a patch never sets it.

  Seeded: sequence `n` is the same on every run. `SEQUENCES` sets how many
  run per surface at compile time (default #{20}; 300 take about four
  minutes). The two sequences the reviews found are also run by name.

  300 per surface, when written: 0 fail with `StudioLive.PostedEdits`; 240 of
  600 fail on main (a post that changes nothing left the typed-away value in
  the buffer, and after a tab switch it was drawn and stored); 278 and 66
  fail on the two earlier heads of #26396.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.SingleEditorSaveSequences.Refuse

  @dataset "production"
  @steps 14
  @default_sequences 20
  @sequences String.to_integer(System.get_env("SEQUENCES") || "#{@default_sequences}")

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string", "group" => "one"},
    %{"name" => "f", "title" => "F", "type" => "string", "group" => "one"},
    %{"name" => "g", "title" => "G", "type" => "string", "group" => "one"},
    %{"name" => "summary", "title" => "Summary", "type" => "string", "group" => "one"},
    %{
      "name" => "stage",
      "title" => "Stage",
      "type" => "select",
      "options" => ["open", "done"],
      "group" => "one"
    },
    %{
      "name" => "must",
      "title" => "Must",
      "type" => "string",
      "group" => "two",
      "validation" => %{"required" => true}
    },
    %{"name" => "other", "title" => "Other", "type" => "string", "group" => "two"}
  ]

  @groups [
    %{"name" => "one", "title" => "One", "default" => true},
    %{"name" => "two", "title" => "Two"}
  ]

  @names ~w(title f g summary stage must other)
  @start %{"f" => "f0", "g" => "g0", "stage" => "open", "other" => "o0"}

  # {field, weight, the values a step may type}. The first value is the one
  # the document starts with; it is chosen half of the time.
  @typing %{
    "one" => [
      {"f", 7, ["f0", "f typed", "f NEEDS", "FAIL f"]},
      {"g", 6, ["g0", "g1", "g2"]},
      {"summary", 2, ["", "s"]},
      {"stage", 2, ["open", "done"]}
    ],
    "two" => [{"must", 5, ["", "here"]}, {"other", 2, ["o0", "o1"]}]
  }
  @switch_weight 4

  setup %{conn: conn} do
    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([Refuse])
    previous = Application.get_env(:barkpark, Barkpark.Content.Validation)

    on_exit(fn ->
      Barkpark.PluginEnv.restore(prior)

      if previous,
        do: Application.put_env(:barkpark, Barkpark.Content.Validation, previous),
        else: Application.delete_env(:barkpark, Barkpark.Content.Validation)
    end)

    type = "seq_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Sequences",
          "visibility" => "public",
          "groups" => @groups,
          "fields" => @fields
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "seq-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "seq", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, type: type, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"}
  end

  # Ten sequences a test: one test holds its database connection for two
  # minutes at most.
  for surface <- [:studio, :desk], first <- Enum.take_every(1..@sequences//1, 10) do
    @surface surface
    @range first..min(first + 9, @sequences)

    test "#{surface}, sequences #{first}..#{min(first + 9, @sequences)}: nothing typed away is stored or drawn",
         c do
      failures =
        for n <- @range do
          :rand.seed(:exsss, {n, 26_396, 1})
          run(c, @surface, "sequence #{n}", rem(n, 2) == 0, :random)
        end

      assert_none(failures)
    end
  end

  # The two sequences the reviews of #26396 found by hand.
  for surface <- [:studio, :desk] do
    @surface surface

    test "#{surface}: a refused value typed back, then two other changes (first review)", c do
      ops = [
        {:type, "f", "f NEEDS"},
        {:type, "f", "f0"},
        {:type, "summary", "s"},
        {:type, "g", "g1"}
      ]

      assert_none([run(c, @surface, "first review", true, ops)])
    end

    test "#{surface}: unsaved because of another tab's field, typed back after it is filled (second review)",
         c do
      ops = [
        {:type, "f", "f typed"},
        :switch,
        {:type, "must", "here"},
        :switch,
        {:type, "f", "f0"},
        {:type, "g", "g1"},
        {:type, "g", "g2"}
      ]

      assert_none([run(c, @surface, "second review", false, ops)])
    end
  end

  defp assert_none(results) do
    failures = Enum.reject(results, &is_nil/1)

    assert failures == [],
           "#{length(failures)} sequences failed. The first:\n" <> List.first(failures, "")
  end

  # ── One sequence ──────────────────────────────────────────────────────────

  # Runs `ops` (a list, or `:random` for #{@steps} generated steps) on a new
  # document. Returns nil, or the steps with each failed check.
  defp run(c, surface, label, with_must?, ops) do
    doc_id = "#{c.type}-#{surface}-#{System.unique_integer([:positive])}"
    content = if with_must?, do: Map.put(@start, "must", "here"), else: @start

    # The document without `must` is in the store from before the dataset
    # enforced its schema.
    Application.put_env(:barkpark, Barkpark.Content.Validation, enforce_datasets: [])

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => doc_id, "title" => "Old title", "content" => content},
        @dataset
      )

    Application.put_env(:barkpark, Barkpark.Content.Validation, enforce_datasets: [@dataset])

    {url, sel} =
      case surface do
        :studio -> {"#{c.base}/#{c.type}/#{doc_id}", "#editor-form"}
        :desk -> {"#{c.base}/_desk/#{c.type};#{doc_id}", "[data-pane-editing] #editor-form"}
      end

    {:ok, view, _html} = live(c.conn, url)
    render_async(view, 5_000)
    assert Enum.any?(1..200, fn _ -> has_element?(view, sel) or (Process.sleep(10) && false) end)
    page = {view, sel}
    store = stored(c, doc_id)

    state = %{
      tab: "one",
      # What the person has in each input they have seen.
      dom: drawn(page),
      # What the person last typed in each field; the start value otherwise.
      meant: store,
      store: store,
      failed?: false,
      log: ["start (must #{if with_must?, do: "stored", else: "missing"}): #{inspect(store)}"]
    }

    ops = if ops == :random, do: List.duplicate(:random, @steps), else: ops

    state =
      ops
      |> Enum.with_index(1)
      |> Enum.reduce(state, fn {op, i}, state ->
        op = if op == :random, do: random_op(state), else: op
        {state, typed} = step(page, state, op, i)
        now = stored(c, doc_id)
        whys = check(page, state, now, typed)

        %{
          state
          | store: now,
            failed?: state.failed? or whys != [],
            log: Enum.map(whys, &("   " <> &1)) ++ state.log
        }
      end)

    GenServer.stop(view.pid)

    if state.failed?,
      do: "#{surface} #{label}:\n  " <> (state.log |> Enum.reverse() |> Enum.join("\n  "))
  end

  defp random_op(state) do
    typing = Map.fetch!(@typing, state.tab)
    total = @switch_weight + Enum.sum(for {_, w, _} <- typing, do: w)
    roll = :rand.uniform(total)

    if roll <= @switch_weight do
      :switch
    else
      {name, values} = pick(typing, roll - @switch_weight)
      value = if :rand.uniform(2) == 1, do: hd(values), else: Enum.random(tl(values))
      {:type, name, value}
    end
  end

  defp pick([{name, weight, values} | rest], roll) do
    if roll <= weight, do: {name, values}, else: pick(rest, roll - weight)
  end

  # Returns the state and the field typed in (nil for a tab switch).
  defp step({view, _sel} = page, state, :switch, i) do
    tab = if state.tab == "one", do: "two", else: "one"
    view |> element("#bp-group-tab-#{tab}") |> render_click()
    # The inputs of the tab now shown are drawn anew.
    {%{state | tab: tab, dom: drawn(page), log: ["#{i}. open tab #{tab}" | state.log]}, nil}
  end

  defp step({view, sel} = page, state, {:type, name, value}, i) do
    dom = Map.put(state.dom, name, value)
    view |> element(sel) |> render_change(%{"_target" => ["doc", name], "doc" => dom})
    # The patch: every input but the one typed in shows what the server draws.
    dom = Map.merge(drawn(page), %{name => value})

    state = %{
      state
      | dom: dom,
        meant: Map.put(state.meant, name, value),
        log: ["#{i}. type #{name} = #{inspect(value)}" | state.log]
    }

    {state, name}
  end

  # A patch never sets the input being typed in, so `typed` is not checked
  # against what the server draws until the person is somewhere else.
  defp check(page, state, now, typed) do
    moved =
      for name <- @names, now[name] != state.store[name], now[name] != state.meant[name] do
        "STORED: #{name} went from #{inspect(state.store[name])} to #{inspect(now[name])}; " <>
          "the person last typed #{inspect(state.meant[name])}"
      end

    shown =
      for {name, value} <- drawn(page), name != typed, value != state.meant[name] do
        "DRAWN: the #{name} input shows #{inspect(value)}; the person last typed " <>
          inspect(state.meant[name])
      end

    moved ++ shown
  end

  # ── The page and the store ────────────────────────────────────────────────

  # What the server draws now: name => value for each field input in the form.
  defp drawn({view, sel}) do
    form = view |> element(sel) |> render() |> LazyHTML.from_fragment()

    for name <- @names, value = drawn_value(form, name), into: %{}, do: {name, value}
  end

  defp drawn_value(form, name) do
    select = LazyHTML.query(form, ~s(select[name="doc[#{name}]"]))
    input = LazyHTML.query(form, ~s|input[name="doc[#{name}]"]:not([type="hidden"])|)

    cond do
      Enum.count(select) > 0 ->
        select
        |> LazyHTML.query("option[selected]")
        |> LazyHTML.attribute("value")
        |> List.first("")

      Enum.count(input) > 0 ->
        input |> LazyHTML.attribute("value") |> List.first("")

      true ->
        nil
    end
  end

  # name => stored value, an absent or nil field as "".
  defp stored(c, doc_id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, doc_id, @dataset)
    content = Map.put(doc.content || %{}, "title", doc.title)
    Map.new(@names, fn name -> {name, Map.get(content, name) || ""} end)
  end
end
