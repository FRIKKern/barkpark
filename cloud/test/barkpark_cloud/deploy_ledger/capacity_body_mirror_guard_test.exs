defmodule BarkparkCloud.DeployLedger.CapacityBodyMirrorGuardTest do
  @moduledoc """
  THE GUARD THAT KEEPS THE MIRROR FROM GROWING A FOURTH FACE.

  The box's `box_at_capacity` 409 message has exactly one copy in this repo:
  `api/test/support/fixtures/box_capacity_refusal.json`, which the api/ suite
  asserts the real emitter still produces. This guard walks EVERY `.exs` under
  `cloud/test` and fails on any file that hand-types that body as a literal
  instead of reading it through `BarkparkCloud.BoxCapacityRefusalFixture`.

  WHY A SCANNER AND NOT A LIST. The three known sites were found the way a
  reader would find them — by grepping the emitter's own distinctive fragments
  ("build slots in use", "box is at its build capacity", "box_at_capacity")
  across `api/` and `cloud/`. A guard that hard-codes those three paths is the
  same hand-copied list it is supposed to be replacing: it would wave through a
  fourth copy pasted into a new file tomorrow, which is exactly how the first
  drift survived a fix (#16581 corrected one site, #16598 the other two, a day
  later). So the needle is DERIVED — taken from the shared fixture at run time,
  never typed here — and the haystack is the whole tree, enumerated.

  WHY IT CANNOT GO BLIND. A scanner over a tree that quietly reads nothing
  reports "no copies found" and prints green forever. Three positive controls
  below: it must enumerate a non-trivial number of real files, it must FIND a
  planted copy in a synthetic corpus, and it must find the copy that is legally
  present in the fixture file itself.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.BoxCapacityRefusalFixture, as: Fx

  @cloud_test_root Path.expand("../..", __DIR__)

  # The one file allowed to hand-type nothing at all but is scanned anyway, and
  # this guard's own source, whose docstring quotes fragments on purpose.
  @self Path.relative_to(__ENV__.file, Path.expand("../../..", __DIR__))

  defp exs_files do
    Path.wildcard(Path.join(@cloud_test_root, "**/*.exs"))
  end

  # THE NEEDLE IS DERIVED, never retyped: the longest part of the emitted
  # message, straight out of the shared fixture. Deriving it means a re-worded
  # refusal re-aims the guard automatically instead of leaving it hunting a
  # string that no longer exists.
  defp needles do
    parts = Fx.parts()
    message = Fx.message()

    candidates = [message | parts]

    needles = candidates |> Enum.filter(&(String.length(&1) >= 20)) |> Enum.uniq()

    # REFUSE ON AN EMPTY DERIVATION. An empty needle list matches nothing and
    # the guard passes on every possible tree.
    assert needles != [],
           "derived NO needle from the shared fixture at #{Fx.path()} — this guard would pass vacuously"

    needles
  end

  defp offenders(files, needles) do
    for path <- files,
        source = File.read!(path),
        Enum.any?(needles, &String.contains?(source, &1)),
        do: Path.relative_to(path, Path.expand("../../..", __DIR__))
  end

  describe "positive control — the scanner can see" do
    test "it enumerates a real, non-trivial corpus of cloud test files" do
      files = exs_files()

      # A wildcard that resolves to nothing (wrong root, moved tree) is the
      # classic way a tree scanner goes silently vacuous.
      assert length(files) > 50,
             "the scanner enumerated only #{length(files)} .exs files under #{@cloud_test_root} — that is not the cloud test tree, and every verdict below would be meaningless"

      assert Enum.any?(files, &String.ends_with?(&1, "deploy_ledger_test.exs")),
             "the scanner did not enumerate deploy_ledger_test.exs — its root is wrong"
    end

    test "it FINDS a planted hand-typed copy" do
      needles = needles()

      dir = Path.join(System.tmp_dir!(), "bp-cap-guard-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "nested"))
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "innocent_test.exs"), """
      defmodule InnocentTest do
        @detail "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight"
      end
      """)

      planted = Path.join([dir, "nested", "planted_test.exs"])

      File.write!(planted, """
      defmodule PlantedTest do
        @d_capacity "the instance refused the deploy (HTTP 409): box_at_capacity — #{Fx.message()}"
      end
      """)

      found = offenders(Path.wildcard(Path.join(dir, "**/*.exs")), needles)

      assert Enum.any?(found, &String.ends_with?(&1, "planted_test.exs")),
             "the scanner MISSED a planted hand-typed copy — it cannot see, so its clean verdict on the real tree proves nothing. found: #{inspect(found)}"

      refute Enum.any?(found, &String.ends_with?(&1, "innocent_test.exs")),
             "the scanner flagged a file carrying a DIFFERENT refusal — it is matching too broadly"
    end

    test "it finds the body where the body is legally allowed to live" do
      # The shared fixture file itself contains the string. If the matcher
      # cannot find it THERE, it is not matching the real body at all.
      assert File.read!(Fx.path()) =~ Fx.message()
    end
  end

  describe "the lock" do
    test "no cloud test hand-types the box's capacity refusal body" do
      needles = needles()

      found =
        exs_files()
        |> offenders(needles)
        |> Enum.reject(&(&1 == @self))

      assert found == [], """
      A HAND-TYPED COPY OF THE BOX'S CAPACITY REFUSAL IS BACK.

        offending file(s): #{Enum.join(found, ", ")}
        emitter          : api/lib/barkpark_web/controllers/site_deploy_controller.ex
                           (capacity_message/3 <> peer_tail/1)
        the one copy     : #{Fx.path()}

      That string has exactly one home, and the api/ suite
      (BarkparkWeb.SiteDeployCapacityBodyConformanceTest) asserts the real
      emitter still produces it. A second copy here is an unlocked mirror: it
      can drift from the emitter and this suite will stay green, because
      `classify_deferred/2` only reads the `box_at_capacity` code word and
      every other byte of the sentence is free to rot.

      Use it instead:

          alias BarkparkCloud.BoxCapacityRefusalFixture
          @d_capacity BoxCapacityRefusalFixture.deferred_detail() <> @requeued
      """
    end

    test "THE CENSUS: no fixture claims to carry the box's body and then invents one" do
      # Arm A above catches a hand-typed copy of the CORRECT body. It cannot
      # see the failure that actually shipped: a fixture that claims the box's
      # body and carries an INVENTED one. Reverting a corrected fixture to
      # `"… box_at_capacity — 4 of 4 build slots are in use"` and running
      # test/barkpark_cloud/deploy_ledger/ gave 10 tests, 0 failures — the
      # needle Arm A hunts is precisely what a drifted copy no longer has.
      #
      # So this arm keys on the CLAIM, not the body: the persisted refusal
      # shape `<409 caption>: <code> — <prose>`. Whatever prose follows must
      # be the box's, and the only way to be the box's is to come from the
      # shared fixture — after which no such literal exists in the file at all.
      claim = claim_regex()

      offenders =
        for path <- exs_files(),
            rel = Path.relative_to(path, Path.expand("../../..", __DIR__)),
            rel != @self,
            [_ | _] = hits <- [Regex.scan(claim, File.read!(path))],
            bad = for([_, prose] <- hits, not String.starts_with?(prose, Fx.prefix()), do: prose),
            bad != [],
            do: {rel, bad}

      assert offenders == [], """
      A FIXTURE CLAIMS TO CARRY THE BOX'S CAPACITY REFUSAL AND INVENTED ONE.

      #{Enum.map_join(offenders, "\n", fn {rel, bad} -> "  #{rel}\n    carries: #{inspect(bad)}" end)}

        it should carry: #{inspect(Fx.prefix())}…
        emitter        : api/lib/barkpark_web/controllers/site_deploy_controller.ex
                         (capacity_message/3 <> peer_tail/1)
        the one copy   : #{Fx.path()}

      This is the exact drift that shipped for a day (#16581 corrected one
      site, #16598 the other two) with every suite green: `classify_deferred/2`
      reads only the `box_at_capacity` code word, so an invented tail still
      classifies BOX_AT_CAPACITY_DEFERRED and no assertion notices. Build the
      string from `BarkparkCloud.BoxCapacityRefusalFixture.deferred_detail/0`.
      """
    end

    test "the CLAIM detector fires on the body that actually shipped" do
      # POSITIVE CONTROL for the arm above, on the REAL historical needle —
      # not a needle invented for the test. If this stops firing, the census
      # has gone blind in exactly the direction that cost a day.
      claim = claim_regex()

      drifted = Fx.refusal_caption() <> ": box_at_capacity — 4 of 4 build slots are in use"
      honest = Fx.deferred_detail()

      assert [[_, prose]] = Regex.scan(claim, ~s("#{drifted}"))
      refute String.starts_with?(prose, Fx.prefix())

      assert [[_, ok_prose]] = Regex.scan(claim, ~s("#{honest}"))

      assert String.starts_with?(ok_prose, Fx.prefix()),
             "the detector rejects the READER's own output — it would red on a correct tree"
    end

    test "the value the fixtures receive is the real thing, not a hole" do
      # Non-vacuity for the READER: if `deferred_detail/0` ever degraded to the
      # bare prefix, every classifier assertion downstream would still pass on
      # the code word alone and nothing would notice.
      detail = Fx.deferred_detail()

      assert detail =~ "box_at_capacity"
      assert String.contains?(detail, Fx.message())
      assert String.contains?(detail, Fx.holding_slug())
      assert String.length(Fx.message()) > 60
    end
  end

  # ── the claim detector, DERIVED from both producers ──────────────────────
  #
  # A fixture CLAIMS to carry the box's capacity refusal when it holds the
  # persisted shape `<409 caption>: box_at_capacity — <prose>`: the caption
  # `Sites.Deploy` writes, the code word the controller sends, and a message
  # segment. `[^"]*` stops at the end of the string literal, so the match is
  # the claimed body and nothing after it.
  #
  # Both halves are checked against the sources that produce them, so a rename
  # on either side reds here instead of leaving the detector hunting a string
  # that no longer exists.
  defp claim_regex do
    assert File.read!(Fx.emitter_path()) =~ ~s(code: "box_at_capacity"),
           "the controller no longer sends `box_at_capacity` — re-derive this detector from #{Fx.emitter_path()}"

    assert File.read!(deploy_source()) =~ "the instance refused the deploy (HTTP ",
           "Sites.Deploy no longer writes the anchored 409 caption — re-derive this detector from #{deploy_source()}"

    Regex.compile!(Regex.escape(Fx.refusal_caption() <> ": box_at_capacity — ") <> "([^\"]*)")
  end

  defp deploy_source,
    do: Path.expand("../../../lib/barkpark_cloud/sites/deploy.ex", __DIR__)
end
