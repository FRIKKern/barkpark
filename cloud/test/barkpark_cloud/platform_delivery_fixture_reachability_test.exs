defmodule BarkparkCloud.PlatformDeliveryFixtureReachabilityTest do
  use ExUnit.Case, async: true

  @moduledoc """
  THE FIXTURE MUST NOT TEACH A SHAPE THE WIRE CANNOT CARRY.

  `cloud/priv/static/__fixtures__/platform_deliveries.json` carried
  `queued_pickup_seconds: 3` and `queued_stall_seconds: 5` on five scenarios —
  values NO producer in the tree can ever write. Both columns are hard-coded
  `null` literals in the one and only producer (the `record-delivery` job in
  `.github/workflows/deploy.yml`) and are CORRECTLY null by charter D484: D430
  defines `pickup` as THE RESIDUAL of a three-term partition and never as a
  threshold, and the third term (`stall`) needs a repo-wide cross-workflow query
  the recorder does not make.

  The fix is NOT to fill the columns (D484 refuses it by name) and NOT to delete
  them (they render in the CLI's three-way wait split). It is to make the
  fixture SAY so — and this file is what stops that saying from rotting into
  prose nobody re-derives.

  ## Why a nullability test would not have caught this

  The fixture already declared these columns nullable and a Go test already
  pinned that declaration. **Nullable is not the same question as writable.**
  Nullable says a live row MAY carry null; reachable says a producer CAN emit
  something else. Every existing pin answered the first question, so a fixture
  demonstrating two buckets no producer can fill stayed green for three waves.

  ## The load-bearing arm

  Arm 2 does not read the fixture's word for it. It parses the PRODUCER's own
  payload map out of `.github/workflows/deploy.yml` and derives which columns
  are written as the literal token `null`. If someone ever teaches the recorder
  to compute `queued_pickup_seconds`, this file REDS and names D484 — which is
  the point: filling that column is a charter amendment, and a charter amendment
  should not be able to land as a quiet green.

  `.github/workflows/deploy.yml` is a repo-root read from `cloud/test`. It is
  already inside CLOUD_PATHS (`scripts/cloud-path-escape-check.sh`), so this
  file adds no new escape — `payload_key_set_census_test.exs` reads the same
  file for the same reason.
  """

  @fixture_path Path.expand("../../priv/static/__fixtures__/platform_deliveries.json", __DIR__)
  @repo_root Path.expand("../../..", __DIR__)
  @deploy_yml Path.join(@repo_root, ".github/workflows/deploy.yml")

  setup_all do
    # NEVER a clean tree: a wrong root would read nothing, derive an empty
    # null-column set, and pass vacuously against any fixture at all.
    unless File.regular?(@deploy_yml) do
      raise "platform-delivery reachability: #{@deploy_yml} is not this repo's deploy.yml"
    end

    fixture = @fixture_path |> File.read!() |> Jason.decode!()
    {:ok, fixture: fixture, deploy_yml: File.read!(@deploy_yml)}
  end

  # ---------------------------------------------------------------------------
  # arm 1 — the declaration is a PARTITION of the wire, with nothing unclassified
  # ---------------------------------------------------------------------------

  test "every key on the wire is classified exactly once as writable or unreachable", %{
    fixture: fx
  } do
    live = Enum.sort(fx["live_key_set"])
    pr = fx["producer_reachability"]
    writable = pr["writable"]
    unreachable = pr["unreachable"]

    both = Enum.filter(writable, &(&1 in unreachable))

    assert both == [],
           "these keys are declared BOTH writable and unreachable: #{inspect(both)}"

    assert Enum.sort(writable ++ unreachable) == live,
           "producer_reachability must partition live_key_set exactly.\n" <>
             "  unclassified: #{inspect(live -- Enum.sort(writable ++ unreachable))}\n" <>
             "  not on the wire: #{inspect(Enum.sort(writable ++ unreachable) -- live)}"
  end

  # ---------------------------------------------------------------------------
  # arm 2 — THE ANTI-ROT ARM. Derived from the producer, never from the fixture.
  # ---------------------------------------------------------------------------

  test "the declared unreachable set IS the set the producer hard-codes to null", %{
    fixture: fx,
    deploy_yml: yml
  } do
    declared = Enum.sort(fx["producer_reachability"]["unreachable"])
    derived = Enum.sort(hard_null_columns(yml))

    assert derived != [],
           "no `<column>: null` literal was found in deploy.yml's payload map — the parser is " <>
             "looking at the wrong thing, and every assertion below it would pass vacuously"

    assert declared == derived,
           """
           producer_reachability.unreachable disagrees with the producer.

             declared in the fixture : #{inspect(declared)}
             derived from deploy.yml : #{inspect(derived)}

           If a column MOVED OUT of the derived set, the recorder now computes it.
           That is charter D484 territory: D430 defines `queued_pickup_seconds` as
           THE RESIDUAL of a three-term partition and never as a threshold, and
           filling it is a charter amendment wearing a null-fill. Amend D484
           deliberately — do not update this list to make the red go away.
           """
  end

  test "the parser can tell a computed column from a hard-null one (arm 2 can fail)" do
    # POSITIVE CONTROL: today's real shape — self computed, the other two nulled.
    real =
      "map({queued_self_seconds: $self, queued_pickup_seconds: null, queued_stall_seconds: null})"

    assert Enum.sort(hard_null_columns(real)) == ["queued_pickup_seconds", "queued_stall_seconds"]

    # THE MUTATION arm 2 exists to catch: pickup becomes computed. The derived
    # set shrinks, so a fixture still declaring it unreachable REDS.
    filled =
      "map({queued_self_seconds: $self, queued_pickup_seconds: $pickup, queued_stall_seconds: null})"

    assert hard_null_columns(filled) == ["queued_stall_seconds"]

    # And the reverse mutation: a column that stops being computed must be
    # declared, or arm 2 reds the other way.
    emptied =
      "map({queued_self_seconds: null, queued_pickup_seconds: null, queued_stall_seconds: null})"

    assert Enum.sort(hard_null_columns(emptied)) ==
             ["queued_pickup_seconds", "queued_self_seconds", "queued_stall_seconds"]
  end

  test "queued_self_seconds is COMPUTED by the producer, not nulled", %{deploy_yml: yml} do
    refute "queued_self_seconds" in hard_null_columns(yml),
           "queued_self_seconds is no longer computed by the recorder. It is the ONE bucket of " <>
             "D430's three that production can measure; if it has gone null, the queue split now " <>
             "carries no measured term at all and `producer_shape_self_only` is fiction."
  end

  # ---------------------------------------------------------------------------
  # arm 3 — the fixture DEMONSTRATES the law, not merely states it
  # ---------------------------------------------------------------------------

  test "at least one scenario carries the shape production actually emits", %{fixture: fx} do
    unreachable = fx["producer_reachability"]["unreachable"]

    reachable_rows =
      for {name, sc} <- fx["scenarios"],
          sc["status"] == 200,
          row <- sc["body"]["deliveries"],
          Enum.all?(unreachable, &is_nil(row[&1])),
          Enum.any?(["queued_seconds", "queued_self_seconds", "build_seconds"], &row[&1]),
          do: name

    assert reachable_rows != [],
           "NO scenario carries a producible row: every 200 scenario either populates a column no " <>
             "producer can write, or nulls every clock. The reachable render path — one measured " <>
             "bucket beside two UNMETERED ones — would have no coverage at all."
  end

  test "the producible scenario's split does NOT add up, and that is the point", %{fixture: fx} do
    row = hd(fx["scenarios"]["producer_shape_self_only"]["body"]["deliveries"])

    assert is_nil(row["queued_pickup_seconds"])
    assert is_nil(row["queued_stall_seconds"])
    assert is_integer(row["queued_self_seconds"])
    assert is_integer(row["queued_seconds"])

    # 465 total vs 362 self: 103 measured seconds sit in NO bucket, because two
    # of the three buckets cannot be written. A reader that treats the split as
    # a partition of the total loses them silently — or coalesces the nulls to 0
    # and reports the whole wait as self-inflicted.
    assert row["queued_seconds"] > row["queued_self_seconds"],
           "this scenario exists to show a split that does not sum to its total. If they are equal " <>
             "the fixture stops demonstrating the residual an operator cannot see, and a reader " <>
             "that assumed the buckets partition the total would pass against it."
  end

  # ---------------------------------------------------------------------------
  # arm 4 — a scenario carrying an unreachable value must SAY it is unreachable
  # ---------------------------------------------------------------------------

  test "every scenario populating an unreachable column labels it as such", %{fixture: fx} do
    unreachable = fx["producer_reachability"]["unreachable"]

    offenders =
      for {name, sc} <- fx["scenarios"],
          sc["status"] == 200,
          Enum.any?(sc["body"]["deliveries"], fn row ->
            Enum.any?(unreachable, &(not is_nil(row[&1])))
          end),
          not String.contains?(sc["synthetic"] || "", "producer_reachability"),
          do: name

    assert offenders == [],
           """
           these scenarios populate a column no producer can write, without pointing at the
           block that says so: #{inspect(Enum.sort(offenders))}

           They are allowed to exist — the CLI renders those shapes and an unrendered branch
           rots — but the label must name `producer_reachability` so a reader cannot mistake
           a render exercise for evidence about the wire.
           """
  end

  # ---------------------------------------------------------------------------

  # Every `<column>: null` written as a literal inside the recorder's payload
  # map. Scoped to the queue vocabulary of THIS table so an unrelated
  # `something: null` elsewhere in the workflow cannot enter the census.
  defp hard_null_columns(yml) do
    ~r/([a-z_]+):\s*null\b/
    |> Regex.scan(yml)
    |> Enum.map(fn [_, col] -> col end)
    |> Enum.filter(&String.starts_with?(&1, "queued_"))
    |> Enum.uniq()
  end
end
