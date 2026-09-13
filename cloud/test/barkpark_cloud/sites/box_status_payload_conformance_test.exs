defmodule BarkparkCloud.Sites.BoxStatusPayloadConformanceTest do
  @moduledoc """
  THE CONSUMER-SIDE HALF OF THE BOX STATUS/RECORD PAYLOAD LOCK, plus the guard
  that keeps the mirror from growing a fourth face.

  `BarkparkWeb.SiteDeployController` (the OTHER app) emits two payloads this one
  consumes: the poll body `BarkparkCloud.Sites.Deploy.normalize_report/1` reads,
  and the durable record `BarkparkCloud.Sites.BuildLog` renders. Both key sets
  have exactly one copy in this repo —
  `api/test/support/fixtures/box_status_payload.json` — which the api suite
  asserts the real emitter still produces.

  Four arms, and each can lose:

    1. **PRODUCER RE-DERIVED HERE.** The emitter's key sets are extracted from
       the api source at run time and compared to the JSON. So renaming or
       dropping a key on the api producer reds THIS test — the consumer's test,
       in the consumer's suite — with nobody having touched the fixture. That is
       the direction the two hand-written snapshots could never see.
    2. **CONSUMER PROVEN BEHAVIOURALLY.** A body built from the JSON, one
       DISTINCT sentinel per key, is fed to `normalize_report/1`; every
       `consumed` key's sentinel must come out, and mutating the
       `producer_only` keys must change nothing. So dropping a key from the
       consumer reds here too, and so does the consumer quietly starting to read
       a key the JSON classifies as ignored.
    3. **THE RECORD ALLOWLIST, STRICT EQUALITY.** `BuildLog` renders from a
       hand-typed `@record_keys` allowlist. It is compared to the JSON through
       `BuildLog.wire/3` itself — the real renderer, not the attribute — so a key
       the producer sends and the allowlist omits is a red instead of a silent
       drop. It already WAS a silent drop: `route_status`/`route_detail` reached
       the record door in #17640 and never reached an operator.
    4. **NOBODY RETYPES IT.** A scanner walks every `.exs` under `cloud/test`
       and `api/test` and fails on any list literal that re-states either key
       set.

  WHY THE SCANNERS CANNOT GO BLIND. A derivation or a tree walk that quietly
  reads nothing reports agreement and prints green forever. Every arm below
  refuses an empty derivation, and each scanner carries a positive control: it
  must find a PLANTED specimen in a synthetic corpus, and must not flag an
  innocent neighbour.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.BoxStatusPayloadFixture, as: Fx
  alias BarkparkCloud.Sites.BuildLog
  alias BarkparkCloud.Sites.Deploy

  @repo_root Path.expand("../../../..", __DIR__)
  @self Path.relative_to(__ENV__.file, @repo_root)

  @scan_roots ~w(cloud/test api/test)

  # ── ARM 1: the PRODUCER, re-derived from the api source ───────────────────

  describe "arm 1 — the api producer's key sets, extracted here" do
    test "the extractor can SEE (positive control on a synthetic source)" do
      planted = """
      defmodule Fake do
        defp render_status(status) do
          %{
            state: status.state,
            # a comment: not_a_key: nope
            planted_key: status.planted
          }
        end
      end
      """

      assert emitter_keys(planted, "render_status(status)") == ~w(planted_key state),
             "the extractor cannot read a map literal it was handed — every verdict below would be meaningless"
    end

    test "the extractor REFUSES a function it cannot find, instead of returning nothing" do
      assert_raise RuntimeError, ~r/could not locate/, fn ->
        emitter_keys("defmodule Empty do\nend\n", "render_status(status)")
      end
    end

    test "render_status/1's emitted keys are the shared JSON's" do
      derived = emitter_keys(producer_source(), "render_status(status)")

      # `health_exit_code` is put on by `put_health_exit_code/2` AFTER the map
      # literal, so it is not in the literal to extract — which is exactly what
      # the JSON's `conditional` list declares. Asserted, not assumed: the key
      # must appear in the source, and must NOT appear in the literal.
      conditional = Fx.status_conditional()

      for key <- conditional do
        assert producer_source() =~ ":#{key}",
               "#{Fx.rel()} declares #{inspect(key)} conditional, but #{Fx.producer_path()} never mentions it"

        refute key in derived,
               "#{inspect(key)} is in render_status/1's map literal — it is no longer CONDITIONAL, so move it out of status.conditional in #{Fx.rel()}"
      end

      assert derived == Enum.sort(Fx.status_keys() -- conditional),
             drift("render_status/1", derived, Fx.status_keys() -- conditional)
    end

    test "render_stage/1's emitted keys are the shared JSON's" do
      derived = emitter_keys(producer_source(), "render_stage(stage)")

      assert derived == Enum.sort(Fx.stage_keys()),
             drift("render_stage/1", derived, Fx.stage_keys())
    end

    test "render_build_record/1's emitted keys are the shared JSON's" do
      derived = emitter_keys(producer_source(), "render_build_record(record)")

      assert derived == Enum.sort(Fx.record_keys()),
             drift("render_build_record/1", derived, Fx.record_keys())
    end
  end

  # ── ARM 2: the CONSUMER, proven behaviourally ─────────────────────────────

  describe "arm 2 — normalize_report/1 against a body built from the JSON" do
    test "every `consumed` key's sentinel comes out the other side" do
      body = Fx.status_body(%{"state" => "running"})
      out = Deploy.normalize_report(body)

      folded = Fx.status_folded()

      assert folded -- Fx.status_consumed() == [],
             "#{Fx.rel()}: status.folded names a key that is not in status.consumed"

      for key <- Fx.status_consumed(), key not in folded do
        sentinel = Fx.sentinel(key)
        atom = String.to_existing_atom(key)

        assert Map.fetch!(out, atom) == sentinel,
               """
               THE CONTROL PLANE STOPPED CONSUMING A KEY THE BOX SENDS.

                 key      : #{inspect(key)}
                 sent     : #{inspect(sentinel)}
                 received : #{inspect(Map.get(out, atom))}

               #{Fx.rel()} classifies #{inspect(key)} as CONSUMED —
               BarkparkCloud.Sites.Deploy.normalize_report/1 is supposed to read it.
               Either restore the read, or move the key to status.producer_only in
               that file (in the same commit) and say why it is now ignored.
               """
      end

      # The held-out keys are read, but TRANSFORMED rather than echoed, so a
      # sentinel-equality assertion on them would assert the wrong thing. Each is
      # pinned by its own behaviour below — never left unasserted — and the list
      # itself is pinned, so a key moved into `folded` to silence the arm above
      # reds here until somebody writes its behaviour down.
      assert folded == ~w(exit_code log stages state),
             "status.folded in #{Fx.rel()} changed. The four behavioural assertions below are its whole guard; add one for the new key before adding the key."

      # A full sentinel body carries a NON-BLANK `failure_reason`, which is one
      # of the three honest ways `failed?/2` reads a failure — so the run is
      # failed no matter what `state` says. Asserted, not worked around: a body
      # this test builds and does not understand proves nothing.
      assert out.state == :failed
      assert out.stages == []

      # The folded arms below therefore blank `failure_reason` first. Without
      # that they would all read :failed for the same reason and none of them
      # would be measuring the key it names.
      quiet = %{"failure_reason" => nil, "exit_code" => 0}

      # state — the lifecycle word becomes an atom.
      assert Deploy.normalize_report(Fx.status_body(Map.put(quiet, "state", "succeeded"))).state ==
               :succeeded

      # exit_code — read, never echoed: a non-zero code alone makes the run
      # failed. The `quiet` body above is this arm's own CONTROL: same body, code
      # 0, and the verdict is NOT :failed, so the red below is the code and
      # nothing else.
      running = Fx.status_body(Map.put(quiet, "state", "running"))
      assert Deploy.normalize_report(running).state == :running
      assert Deploy.normalize_report(Map.put(running, "exit_code", 12)).state == :failed

      # stages — the structured array is folded into normalized stages.
      assert Deploy.normalize_report(
               Fx.status_body(
                 Map.merge(quiet, %{
                   "state" => "running",
                   "stages" => [%{"name" => "BUILD", "status" => "ok"}]
                 })
               )
             ).stages == [%{name: "BUILD", status: "done", detail: nil}]

      # log — the FALLBACK sink: a run that narrated no stage array still gets
      # its stages, parsed out of the log's BPSTAGE lines.
      assert Deploy.normalize_report(%{
               "state" => "running",
               "log" => "BPSTAGE name=PLAN status=ok build_id=b1"
             }).stages == [%{name: "PLAN", status: "done", detail: nil}]
    end

    test "mutating every `producer_only` key changes NOTHING — the classification is real" do
      base = Fx.status_body(%{"state" => "running"})

      mutated =
        Enum.reduce(Fx.status_producer_only(), base, fn key, acc ->
          Map.put(acc, key, "bp-mutated-" <> key)
        end)

      assert Deploy.normalize_report(mutated) == Deploy.normalize_report(base),
             """
             A KEY CLASSIFIED `producer_only` IS BEING CONSUMED.

               keys mutated: #{inspect(Fx.status_producer_only())}

             #{Fx.rel()} says normalize_report/1 ignores these. It no longer does.
             Move the key it now reads into status.consumed in that file, so the
             sentinel arm above starts guarding it.
             """
    end

    test "every `consumer_only` key is still tolerated — the OLD-box door stays open" do
      # These are not producer keys, so no api-side assertion can reach them.
      # They are the reason `normalize_report/1` is tolerant at all, and an
      # unasserted tolerance is a tolerance that gets refactored away.
      assert Deploy.normalize_report(%{"status" => "succeeded"}).state == :succeeded
      assert Deploy.normalize_report(%{"error" => "boom"}).failure_reason == "boom"
      assert Deploy.normalize_report(%{"url" => "https://x.test"}).url == "https://x.test"

      assert Deploy.normalize_report(%{"console" => ["BPSTAGE name=PLAN status=done"]}).stages ==
               [%{name: "PLAN", status: "done", detail: nil}]

      assert Fx.status_consumer_only() == ~w(console error status url),
             "status.consumer_only in #{Fx.rel()} changed — the four assertions above are its whole guard and one of them is now missing"
    end

    test "normalize_stage/1 reads every `stage.consumed` key" do
      stage = Map.new(Fx.stage_keys(), &{&1, Fx.sentinel(&1)})
      stage = Map.merge(stage, %{"name" => "BUILD", "status" => "failed"})

      assert [got] = Deploy.normalize_report(%{"stages" => [stage]}).stages

      assert Enum.sort(Enum.map(Map.keys(got), &to_string/1)) == Enum.sort(Fx.stage_consumed()),
             drift(
               "normalize_stage/1 output",
               Enum.map(Map.keys(got), &to_string/1),
               Fx.stage_consumed()
             )

      assert got.detail == Fx.sentinel("detail")
    end
  end

  # ── ARM 3: the RECORD allowlist, through the real renderer ────────────────

  describe "arm 3 — BuildLog renders exactly the JSON's record key set" do
    test "a record body carrying every producer key survives the allowlist intact" do
      body = Fx.record_body(%{"slug" => "s", "build_id" => "b1", "log_state" => "available"})

      assert {200, wire} = BuildLog.wire({:ok, 200, body}, "dep-1", "b1")

      # `deployment_id` and `available` are the route's own additions, not the
      # box's record. Subtracted by NAME and asserted present first, so a
      # renamed addition cannot silently widen the comparison.
      assert Map.has_key?(wire, :deployment_id) and Map.has_key?(wire, :available)

      rendered =
        wire
        |> Map.drop([:deployment_id, :available])
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()

      assert rendered == Enum.sort(Fx.record_keys()),
             """
             THE CONTROL PLANE'S RECORD ALLOWLIST DISAGREES WITH THE BOX.

               only the box sends : #{inspect(Enum.sort(Fx.record_keys()) -- rendered)}
               only the route adds: #{inspect(rendered -- Enum.sort(Fx.record_keys()))}

             `@record_keys` in cloud/lib/barkpark_cloud/sites/build_log.ex is an
             ALLOWLIST: a key the box sends and it omits is dropped SILENTLY, on
             the way to an operator reading a failed build. That is not
             hypothetical — `route_status`/`route_detail` were dropped that way
             from #17640 until this lock was built.

             Add the key to `@record_keys` and to `record.emitted` in
             #{Fx.rel()} in the same commit.
             """
    end
  end

  # ── ARM 4: the guard — nobody retypes either list ─────────────────────────

  describe "arm 4 — the guard against a hand-typed copy" do
    test "the corpus is real and non-trivial" do
      files = scan_files()

      assert length(files) > 100,
             "the scanner enumerated only #{length(files)} test files under #{inspect(@scan_roots)} — that is not the test tree, and its clean verdict below would prove nothing"

      assert Enum.any?(files, &String.ends_with?(&1, "site_deploy_controller_test.exs")),
             "the scanner did not reach the api controller test — the tree that held the original hand-typed pin. Its roots are wrong."

      assert Enum.any?(files, &String.ends_with?(&1, "sites_fake_box_relay.ex")),
             "the scanner did not reach the fake box relay — a `.ex`, and one of the three snapshots this lock replaced"
    end

    test "it FINDS a planted retyped list and spares an innocent neighbour" do
      dir = Path.join(System.tmp_dir!(), "bp-status-guard-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "nested"))
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "innocent_test.exs"), """
      defmodule InnocentTest do
        @keys ~w(state slug)
        @other ["exit_code", "failure_reason"]
      end
      """)

      File.write!(Path.join([dir, "nested", "planted_test.exs"]), """
      defmodule PlantedTest do
        @pin ~w(#{Enum.join(Fx.status_keys(), " ")})
      end
      """)

      found = offenders(Path.wildcard(Path.join(dir, "**/*.exs")), dir)

      assert Enum.any?(found, &String.ends_with?(elem(&1, 0), "planted_test.exs")),
             "the scanner MISSED a planted retyped key list — it cannot see, so its clean verdict on the real tree is worthless. found: #{inspect(found)}"

      refute Enum.any?(found, &String.ends_with?(elem(&1, 0), "innocent_test.exs")),
             "the scanner flagged a file naming a couple of keys in passing — it is matching too broadly"
    end

    test "an EMPTY needle set is refused, not passed" do
      # The failure mode this whole file is built against: a derivation that
      # returns nothing matches nothing and certifies every possible tree.
      assert_raise RuntimeError, ~r/no key list/, fn -> overlap_threshold([]) end
    end

    test "no test file re-states either key set" do
      found = offenders(scan_files(), @repo_root)

      assert found == [], """
      A HAND-TYPED COPY OF A BOX PAYLOAD KEY SET IS BACK.

      #{Enum.map_join(found, "\n", fn {rel, hit} -> "  #{rel}\n    restates: #{inspect(hit)}" end)}

        emitter     : api/lib/barkpark_web/controllers/site_deploy_controller.ex
        the one copy: #{Fx.rel()}

      Two copies of one key set is how this drifted in the first place: each
      suite pinned its own snapshot, both stayed green, and the control plane
      silently dropped the box's route verdict for weeks.

      Read it instead:

          alias BarkparkCloud.BoxStatusPayloadFixture
          BoxStatusPayloadFixture.status_keys()      # or .record_keys()
          BoxStatusPayloadFixture.status_body()      # a full body, sentinels and all
      """
    end
  end

  # ── the extractor ─────────────────────────────────────────────────────────
  #
  # The emitter renders each payload as ONE map literal whose entries sit at a
  # fixed six-space indent, so the key set is readable from the source without a
  # parser. Read from the source rather than from a response because this suite
  # cannot boot the other app — and reading it HERE is the whole point of arm 1:
  # it puts the producer's shape under the consumer's own test.

  defp producer_source, do: File.read!(Fx.producer_path())

  defp emitter_keys(source, header) do
    pattern = Regex.compile!("^  defp " <> Regex.escape(header) <> " do\\n(.*?)^  end$", "ms")

    body =
      case Regex.run(pattern, source) do
        [_, body] ->
          body

        _ ->
          raise "could not locate `defp #{header} do` in the producer source — the extractor is hunting a function that no longer exists, and would otherwise report an empty key set as agreement"
      end

    keys =
      ~r/^      ([a-z_]+):\s/m
      |> Regex.scan(body)
      |> Enum.map(fn [_, key] -> key end)
      |> Enum.sort()

    if keys == [] do
      raise "extracted NO keys from `#{header}` — refusing to compare an empty set"
    end

    keys
  end

  # ── the guard's machinery ─────────────────────────────────────────────────

  defp scan_files do
    # BOTH extensions. `cloud/test/support/sites_fake_box_relay.ex` is a `.ex`
    # and it was ONE of the three hand-written snapshots this lock replaced — a
    # scanner that walked only `.exs` would have waved through the very file the
    # row was filed about.
    @scan_roots
    |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**/*.{ex,exs}"])))
  end

  # A file RESTATES a key set when one list literal in it — a `~w(...)` sigil or
  # a bracketed list of strings — names most of that set. Derived from the JSON,
  # never typed here, so a renamed key re-aims the guard automatically.
  defp overlap_threshold(list) do
    if list == [],
      do: raise("no key list to derive a needle from — this guard would pass vacuously")

    max(4, div(length(list) * 2, 3))
  end

  defp offenders(files, root) do
    for path <- files,
        rel = Path.relative_to(path, root),
        rel != @self,
        source = File.read!(path),
        hit = restated(source),
        hit != nil,
        do: {rel, hit}
  end

  defp restated(source) do
    literals =
      Regex.scan(~r/~w\(([^)]*)\)/, source, capture: :all_but_first) ++
        Regex.scan(~r/\[([^\[\]]*)\]/, source, capture: :all_but_first)

    words =
      Enum.map(literals, fn [inner] ->
        Regex.scan(~r/[a-z_]+/, inner) |> Enum.map(fn [w] -> w end) |> MapSet.new()
      end)

    Enum.find_value([{"status", Fx.status_keys()}, {"record", Fx.record_keys()}], fn {name, list} ->
      set = MapSet.new(list)
      need = overlap_threshold(list)

      if Enum.any?(words, &(MapSet.size(MapSet.intersection(&1, set)) >= need)),
        do: "#{name} key set (#{need}+ of #{length(list)} keys in one list literal)"
    end)
  end

  defp drift(fun, got, want) do
    got = Enum.sort(got)
    want = Enum.sort(want)

    """
    THE BOX PAYLOAD MIRROR HAS DRIFTED — seen from the CONSUMER's suite.

    #{fun} now names:
        #{inspect(got)}

    …but #{Fx.rel()} says:
        #{inspect(want)}

      only in the code: #{inspect(got -- want)}
      only in the JSON: #{inspect(want -- got)}

    That JSON is THE ONE COPY, and this test re-derives the producer's shape out
    of #{Fx.producer_path()} precisely so an api-side rename lands
    HERE, in the consumer's suite, rather than staying green on both sides.

    If the change is intended, update #{Fx.rel()} in the SAME
    commit — one line in the right list, kept sorted — and, for a record key,
    `@record_keys` in cloud/lib/barkpark_cloud/sites/build_log.ex too.
    """
  end
end
