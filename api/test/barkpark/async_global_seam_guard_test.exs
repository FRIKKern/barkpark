defmodule Barkpark.AsyncGlobalSeamGuardTest do
  @moduledoc """
  The `api/test` half of the async-env-seam ratchet.

  Same predicate, same script (`scripts/async_env_seam_scan.exs`), same two
  roots as `cloud/test/barkpark_cloud/async_global_seam_guard_test.exs`. Two
  guards rather than one because either tree's suite can be run alone in CI, and
  a ratchet that only fires when somebody happens to run the OTHER project is
  not a ratchet.

  This tree already knew the hazard —
  `api/test/barkpark/application_env_isolation_test.exs` proves the leak channel
  and states the remedy ("serialization is the only thing that stops a
  concurrent reader from observing a mid-test write") — but had no ratchet, so
  two `async: true` swappers accumulated anyway
  (`media/image_backend/vix_test.exs`, `search/intelligence_test.exs`).

  `async: false` for the same fixture reason as its cloud twin: the synthetic
  sources below are literal `Application.put_env(` calls, and the scanner
  deliberately does not exempt itself by filename.
  """
  use ExUnit.Case, async: false

  Code.require_file("../../../scripts/async_env_seam_scan.exs", __DIR__)

  alias Barkpark.AsyncEnvSeamScan

  test "no async: true test module in cloud/test or api/test swaps node-global Application env" do
    result = AsyncEnvSeamScan.scan()

    for {root, count} <- result.scanned do
      refute count == :missing,
             "the ratchet was pointed at #{root}, which does not exist — fix the root, do not delete it"

      assert count > 0, "scanned 0 test files under #{root} — the ratchet is not covering it"
    end

    assert map_size(result.scanned) == 2,
           "expected both the cloud/test and api/test roots, got #{inspect(Map.keys(result.scanned))}"

    assert result.offenders == [], AsyncEnvSeamScan.explain(result.offenders)
  end

  test "the predicate is able to fail — aliased and fully-qualified forms both named" do
    aliased = """
    defmodule Offender do
      use Barkpark.DataCase, async: true
      setup do: Application.put_env(:barkpark, :search_intel_record_async, true)
    end
    """

    qualified = """
    defmodule Offender do
      use ExUnit.Case, async: true
      setup do: Application.put_env(:barkpark, Barkpark.Media.ImageBackend.Vix, [])
    end
    """

    assert %{kind: :async_true_global_env_swap} =
             AsyncEnvSeamScan.inspect_source("aliased.exs", aliased)

    assert %{kind: :async_true_global_env_swap} =
             AsyncEnvSeamScan.inspect_source("qualified.exs", qualified)

    # The formatter wraps a long `use` across two lines; a per-line match sees
    # neither half as a declaration and the module walks through the ratchet.
    wrapped = """
    defmodule Offender do
      use Barkpark.DataCase,
        async: true

      setup do: Application.put_env(:barkpark, :search_intel_record_async, true)
    end
    """

    # `put_all_env` is the bulk form of the same node-global write.
    bulk = """
    defmodule Offender do
      use ExUnit.Case, async: true
      setup do: Application.put_all_env(barkpark: [{Barkpark.Media.ImageBackend.Vix, []}])
    end
    """

    assert %{kind: :async_true_global_env_swap} =
             AsyncEnvSeamScan.inspect_source("wrapped.exs", wrapped)

    assert %{kind: :async_true_global_env_swap} =
             AsyncEnvSeamScan.inspect_source("bulk.exs", bulk)
  end

  test "the predicate does not over-match — async: false and allowlisted both clean" do
    serialized = """
    defmodule Fine do
      use ExUnit.Case, async: false
      setup do: Application.put_env(:barkpark, :media_uploads, [])
    end
    """

    allowed = """
    defmodule Fine do
      # async-env-seam-allow: probe key is unique per test and read by nothing else.
      use ExUnit.Case, async: true
      setup do: Application.put_env(:barkpark, :probe_key, 1)
    end
    """

    # Continuation-joining must not turn every wrapped `use` into an offender:
    # the joined text still has to say `async: true`.
    wrapped_sync = """
    defmodule Fine do
      use Barkpark.DataCase,
        async: false

      setup do: Application.put_env(:barkpark, :search_intel_record_async, true)
    end
    """

    assert AsyncEnvSeamScan.inspect_source("serialized.exs", serialized) == nil
    assert AsyncEnvSeamScan.inspect_source("allowed.exs", allowed) == nil
    assert AsyncEnvSeamScan.inspect_source("wrapped_sync.exs", wrapped_sync) == nil
  end
end
