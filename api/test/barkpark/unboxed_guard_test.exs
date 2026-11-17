defmodule Barkpark.UnboxedGuardTest do
  @moduledoc """
  A nested `unboxed_run` fails loudly instead of leaving committed residue
  (task-8cda3662a8eb6dc2).

  Two halves, and both are needed:

    * at run time, `Barkpark.Unboxed.run/2` raises when its process is already
      inside an unboxed run;
    * at source level, no test file or support module calls `unboxed_run`
      except through `Barkpark.Unboxed`, so the runtime check sees every call.
      The scan parses each file and matches call nodes, so it covers files
      added later, and it ignores the name in comments and docs.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Unboxed

  @test_root Path.expand("../..", __DIR__) |> Path.join("test")
  @wrapper "test/support/unboxed.ex"

  describe "Barkpark.Unboxed.run/2" do
    test "raises when its process is already inside an unboxed run" do
      assert_raise ArgumentError, ~r/inside another unboxed run/, fn ->
        Unboxed.run(fn -> Unboxed.run(fn -> :inner end) end)
      end
    end

    test "after the raise, the process can run unboxed again" do
      assert_raise ArgumentError, fn -> Unboxed.run(fn -> Unboxed.run(fn -> :ok end) end) end
      assert Unboxed.run(fn -> Repo.query!("SELECT 1").rows end) == [[1]]
    end

    test "a Task inside an unboxed run has its own checkout and may run unboxed" do
      assert Unboxed.run(fn ->
               Task.async(fn -> Unboxed.run(fn -> Repo.query!("SELECT 2").rows end) end)
               |> Task.await()
             end) == [[2]]
    end
  end

  describe "the source scan" do
    test "flags a direct unboxed_run, aliased, imported or captured, and passes the wrapper" do
      fixture = """
      defmodule Fixture do
        alias Ecto.Adapters.SQL.Sandbox
        import Ecto.Adapters.SQL.Sandbox, only: [unboxed_run: 2]

        # Sandbox.unboxed_run(Repo, fun) in a comment is not a call
        @doc "nor is unboxed_run/2 in a doc"
        def a, do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> :ok end)
        def b, do: Sandbox.unboxed_run(Repo, fn -> :ok end)
        def c, do: unboxed_run(Repo, fn -> :ok end)
        def d, do: Enum.map([1], &Sandbox.unboxed_run(Repo, fn -> &1 end))
        def e, do: &Sandbox.unboxed_run/2
        def ok, do: Barkpark.Unboxed.run(fn -> :ok end)
      end
      """

      assert {:ok, lines} = direct_calls(fixture)
      assert lines == [7, 8, 9, 10, 11]
    end

    test "no test file or support module calls unboxed_run except through Barkpark.Unboxed" do
      files = Path.wildcard(Path.join(@test_root, "**/*.{ex,exs}"))
      assert length(files) > 1_000, "scanned #{length(files)} files under #{@test_root}"

      found =
        for file <- files,
            rel = Path.relative_to(file, Path.dirname(@test_root)),
            rel != @wrapper,
            hit <- scan(file, rel),
            do: hit

      assert found == [], """
      #{length(found)} direct unboxed_run call(s) or unparseable file(s):

      #{Enum.join(found, "\n")}

      Call Barkpark.Unboxed.run/2 instead. It raises when nested, so a nested
      run cannot leave committed residue (task-8cda3662a8eb6dc2).
      """
    end
  end

  defp scan(file, rel) do
    case direct_calls(File.read!(file)) do
      {:ok, lines} ->
        Enum.map(lines, &"  #{rel}:#{&1}")

      {:error, reason} ->
        ["  #{rel}: does not parse (#{inspect(reason)}); the scan cannot judge it"]
    end
  end

  defp direct_calls(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: false) do
      {_, lines} =
        Macro.prewalk(ast, [], fn
          {{:., meta, [_mod, :unboxed_run]}, _, _} = node, acc ->
            {node, [meta[:line] | acc]}

          {:unboxed_run, meta, args} = node, acc when is_list(args) ->
            {node, [meta[:line] | acc]}

          node, acc ->
            {node, acc}
        end)

      {:ok, lines |> Enum.uniq() |> Enum.sort()}
    end
  end
end
