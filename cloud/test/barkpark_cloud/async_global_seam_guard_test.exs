defmodule BarkparkCloud.AsyncGlobalSeamGuardTest do
  @moduledoc """
  The ratchet for the flake class that made the REQUIRED Cloud control-plane
  gate lie: an `async: true` test module swapping node-global `Application` env.

  The predicate lives in `scripts/async_env_seam_scan.exs` so this tree and
  `api/test` ban the SAME shape — the previous guard's `Path.wildcard/1` was
  relative to `cloud/`, which is precisely why the identical hazard was
  rediscovered from scratch in `api/test`.

  ## Why a shape and not a key list

  The guard this replaces hand-listed `@shared_seam_keys` and substring-matched
  them. Mutation testing broke it BOTH ways — the fully-qualified
  `BarkparkCloud.OAuth` form walked past it, while the async-SAFE `OAuthStub`
  was falsely named by prefix. A gate that reds for a reason other than the one
  it advertises teaches readers to dismiss it, which is how a defect survives
  five waves under three green gates. So the key list is gone: the question
  asked here is the one source text can actually answer.

  ## Why this module is `async: false`

  Not an exemption — a fixture requirement. The synthetic sources below contain
  literal `Application.put_env(` calls as test data, and the scanner deliberately
  does NOT special-case its own guard by filename (self-exclusion is a hole an
  offender can walk through by being renamed). Being `async: false` makes this
  module honestly clean under its own predicate.
  """
  use ExUnit.Case, async: false

  Code.require_file("../../../scripts/async_env_seam_scan.exs", __DIR__)

  alias Barkpark.AsyncEnvSeamScan

  describe "the ratchet over both trees" do
    test "no async: true test module in cloud/test or api/test swaps node-global Application env" do
      result = AsyncEnvSeamScan.scan()

      # A path typo must never read as green: assert each root was really walked.
      for {root, count} <- result.scanned do
        refute count == :missing,
               "the ratchet was pointed at #{root}, which does not exist — fix the root, do not delete it"

        assert count > 0, "scanned 0 test files under #{root} — the ratchet is not covering it"
      end

      assert map_size(result.scanned) == 2,
             "expected both the cloud/test and api/test roots, got #{inspect(Map.keys(result.scanned))}"

      assert result.offenders == [], AsyncEnvSeamScan.explain(result.offenders)
    end
  end

  describe "the predicate is able to fail" do
    test "names an async: true module swapping env via the ALIASED module form" do
      src = """
      defmodule Offender do
        use BarkparkCloud.DataCase, async: true

        setup do
          Application.put_env(:barkpark_cloud, OAuth, client_secret: nil)
        end
      end
      """

      assert %{kind: :async_true_global_env_swap, line: 5} =
               AsyncEnvSeamScan.inspect_source("aliased.exs", src)
    end

    test "names the FULLY-QUALIFIED form the old substring guard walked past" do
      src = """
      defmodule Offender do
        use BarkparkCloud.DataCase, async: true

        setup do
          Application.put_env(:barkpark_cloud, BarkparkCloud.OAuth, client_secret: nil)
        end
      end
      """

      assert %{kind: :async_true_global_env_swap} =
               AsyncEnvSeamScan.inspect_source("qualified.exs", src)
    end

    test "names delete_env too, not just put_env" do
      src = """
      defmodule Offender do
        use ExUnit.Case, async: true
        test "x", do: Application.delete_env(:barkpark_cloud, :usage_fanout_budget_ms)
      end
      """

      assert %{kind: :async_true_global_env_swap} =
               AsyncEnvSeamScan.inspect_source("delete.exs", src)
    end

    test "names a MULTI-LINE use declaration — the formatter wraps long ones" do
      # `mix format` splits `use ...Case, async: true` when the line is long.
      # A per-line match sees neither half as a declaration, and the module
      # walks straight through the ratchet.
      src = """
      defmodule Offender do
        use BarkparkCloud.DataCase,
          async: true

        setup do
          Application.put_env(:barkpark_cloud, OAuth, client_secret: nil)
        end
      end
      """

      assert %{kind: :async_true_global_env_swap, line: 6} =
               AsyncEnvSeamScan.inspect_source("wrapped.exs", src)
    end

    test "names put_all_env — the bulk form of the same node-global write" do
      src = """
      defmodule Offender do
        use ExUnit.Case, async: true
        test "x", do: Application.put_all_env(barkpark_cloud: [{OAuth, []}])
      end
      """

      assert %{kind: :async_true_global_env_swap} =
               AsyncEnvSeamScan.inspect_source("bulk.exs", src)
    end

    test "names a bare allowlist marker carrying no reason" do
      src = """
      defmodule Offender do
        # async-env-seam-allow:
        use ExUnit.Case, async: true
        test "x", do: Application.put_env(:barkpark_cloud, :k, 1)
      end
      """

      assert %{kind: :allowlisted_without_reason} =
               AsyncEnvSeamScan.inspect_source("mute.exs", src)
    end
  end

  describe "the predicate does not over-match" do
    test "an async: false module may swap env freely" do
      src = """
      defmodule Fine do
        use ExUnit.Case, async: false
        test "x", do: Application.put_env(:barkpark_cloud, OAuth, client_secret: nil)
      end
      """

      assert AsyncEnvSeamScan.inspect_source("serialized.exs", src) == nil
    end

    test "an annotated allowlisted module is not named" do
      src = """
      defmodule Fine do
        # async-env-seam-allow: key is written and read only inside this module's
        # own test process and no lib code path reads it.
        use ExUnit.Case, async: true
        test "x", do: Application.put_env(:barkpark_cloud, :private_probe_key, 1)
      end
      """

      assert AsyncEnvSeamScan.inspect_source("allowed.exs", src) == nil
    end

    test "a @moduledoc that merely DISCUSSES the hazard is not named" do
      # registry/cloudflare_credential_test.exs is async: true and says
      # "never smuggled through `Application.put_env`" in prose. Naming it would
      # be the same lying-gate failure in a new coat.
      src = """
      defmodule Fine do
        @moduledoc \"\"\"
        The token is THREADED as an argument — never smuggled through
        `Application.put_env`.
        \"\"\"
        use BarkparkCloud.DataCase, async: true
      end
      """

      assert AsyncEnvSeamScan.inspect_source("prose.exs", src) == nil
    end

    test "the async-SAFE process-dictionary stub is not named by prefix" do
      # The old key-list guard falsely reported OAuthStub as an OAuth offender.
      src = """
      defmodule Fine do
        use ExUnit.Case, async: true
        test "x", do: OAuthStub.put(:harmless, 1)
      end
      """

      assert AsyncEnvSeamScan.inspect_source("stub.exs", src) == nil
    end

    test "a multi-line use declaring async: FALSE is still not named" do
      # The continuation-joining above must not turn every wrapped `use` into
      # an offender — the joined text still has to say `async: true`.
      src = """
      defmodule Fine do
        use BarkparkCloud.DataCase,
          async: false

        setup do
          Application.put_env(:barkpark_cloud, OAuth, client_secret: nil)
        end
      end
      """

      assert AsyncEnvSeamScan.inspect_source("wrapped_sync.exs", src) == nil
    end

    test "a module that swaps env but is NOT a test case is not named" do
      src = """
      defmodule Helper do
        def setup_env, do: Application.put_env(:barkpark_cloud, :k, 1)
      end
      """

      assert AsyncEnvSeamScan.inspect_source("helper.exs", src) == nil
    end
  end
end
