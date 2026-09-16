defmodule Barkpark.CastErrorStatusContractTest do
  @moduledoc """
  THE GROUND TRUTH for the "CastError" folklore, pinned by a run rather than
  quoted from a comment.

  For years comments across this tree said "a non-UUID id would raise
  `Ecto.CastError` → 500". BOTH halves are wrong:

    * **The module.** Binding a non-castable binary to a `:binary_id` column
      raises `%Ecto.Query.CastError{}`. `Ecto.CastError` is a DIFFERENT struct
      (it comes from `Ecto.Type.cast!` / changeset casting, e.g. a mixed
      atom/string-keyed map) and fires ZERO times on the query path. An
      `assert_raise Ecto.CastError` written from the old wording can never
      match — it would look like a guard test and pin nothing.

    * **The status.** `phoenix_ecto` carries a `Plug.Exception` impl for BOTH
      structs mapping them to **400** (`phoenix_ecto/lib/phoenix_ecto/plug.ex`
      — `{Ecto.CastError, 400}, {Ecto.Query.CastError, 400}`). 500 is Plug's
      `Any` fallback (`plug/lib/plug/exceptions.ex`), which on these paths
      covers the nil / non-binary `FunctionClauseError` class instead.

  An unguarded by-id fetch therefore answers an OPAQUE 400 `internal_error`,
  not a 500, and never the clean 404 the caller wanted. That is still a defect
  — it is just not the defect the folklore described, and a builder who writes
  a test from the folklore writes a vacuous one.

  Every arm below carries its own control, so a green here is a green with a
  subject: arm 2 proves the module is NOT `Ecto.CastError`, and arm 3's
  control proves `Plug.Exception.status/1` does not simply answer 400 for
  everything.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Tenancy.Workspace

  @garbage "not-a-uuid"

  describe "the exception module" do
    test "Ecto.Query.CastError and Ecto.CastError are different modules" do
      refute Ecto.Query.CastError == Ecto.CastError
    end

    test "binding a non-UUID to a :binary_id column raises Ecto.Query.CastError, never Ecto.CastError" do
      err =
        assert_raise Ecto.Query.CastError, fn ->
          Repo.one(from(w in Workspace, where: w.id == ^@garbage, select: w.id))
        end

      # CONTROL: name the struct explicitly. `assert_raise` alone would also
      # pass on a subclass-shaped rescue; this pins the exact module.
      assert err.__struct__ == Ecto.Query.CastError
      refute err.__struct__ == Ecto.CastError
    end

    test "CONTROL: a well-formed but absent UUID does NOT raise — the raise is about the CAST" do
      absent = Ecto.UUID.generate()
      assert Repo.one(from(w in Workspace, where: w.id == ^absent, select: w.id)) == nil
    end
  end

  describe "the HTTP status phoenix_ecto maps it to" do
    test "Ecto.Query.CastError is 400, NOT 500" do
      err =
        assert_raise Ecto.Query.CastError, fn ->
          Repo.one(from(w in Workspace, where: w.id == ^@garbage, select: w.id))
        end

      assert Plug.Exception.status(err) == 400
      refute Plug.Exception.status(err) == 500
    end

    test "Ecto.CastError is ALSO 400 — so \"CastError -> 500\" is wrong for either module" do
      # Run-measured, not constructed: `Ecto.UUID.cast!/1` is where
      # `Ecto.CastError` genuinely DOES fire (the changeset/cast! path, never
      # a query bind). phoenix_ecto maps it to 400 as well, so the folklore's
      # "-> 500" is wrong no matter which module the writer meant.
      err = assert_raise Ecto.CastError, fn -> Ecto.UUID.cast!(nil) end

      assert err.__struct__ == Ecto.CastError
      assert Plug.Exception.status(err) == 400
    end

    test "CONTROL: Plug's Any fallback really is 500, so the 400s above discriminate" do
      # The class the folklore actually described: a nil / non-binary id
      # hitting an `is_binary`-headed clause raises FunctionClauseError, which
      # has no phoenix_ecto impl and falls through to Plug's `Any` fallback.
      fce =
        assert_raise FunctionClauseError, fn ->
          String.split(nil, ",")
        end

      assert Plug.Exception.status(fce) == 500
      assert Plug.Exception.status(%RuntimeError{message: "boom"}) == 500
    end
  end

  describe "the folklore cannot come back into api/lib" do
    # A comment fix changes nothing that can red. THIS is the arm that reds:
    # it re-derives the census on every run instead of trusting a snapshot.
    #
    # RULE (a predicate, not a list): inside api/lib, a line that mentions
    # CastError and 500 in the same breath must justify the 500 — the only
    # true reasons are Plug's `Any` fallback / the FunctionClauseError class,
    # an already-`chunked` response phoenix_ecto cannot reach, or a line that
    # is explicitly calling the old phrasing WRONG.
    @justifiers ~w(FunctionClauseError fallback chunked wrong)

    test "no api/lib comment asserts a CastError -> 500 mapping without justifying it" do
      lib = Path.join([File.cwd!(), "lib"])

      offenders =
        lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} ->
            String.contains?(line, "CastError") and
              String.contains?(line, "500") and
              not Enum.any?(@justifiers, &String.contains?(line, &1))
          end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(file, lib)}:#{n}: #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             """
             These api/lib comments assert a "CastError -> 500" mapping.
             phoenix_ecto maps BOTH CastError structs to 400; 500 is Plug's
             `Any` fallback for the FunctionClauseError class. Say 400 (or
             name the real reason the 500 applies):

             #{Enum.join(offenders, "\n")}
             """
    end

    test "CONTROL: the sweep above can actually SEE a violation" do
      # Without this arm the previous test would stay green if the wildcard,
      # the read, or the predicate silently matched nothing. Feed it the exact
      # folklore string and require a hit.
      folklore = "# would raise Ecto.CastError → 500. A malformed id matches no row."

      assert String.contains?(folklore, "CastError")
      assert String.contains?(folklore, "500")
      refute Enum.any?(@justifiers, &String.contains?(folklore, &1))

      # and the corpus it scans is non-empty
      files = Path.wildcard(Path.join([File.cwd!(), "lib", "**/*.ex"]))
      assert length(files) > 100, "the api/lib corpus scanned was #{length(files)} files"
    end
  end
end
