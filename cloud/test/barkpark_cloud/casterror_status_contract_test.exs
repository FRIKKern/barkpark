defmodule BarkparkCloud.CastErrorStatusContractTest do
  @moduledoc """
  THE GROUND TRUTH for the "CastError" folklore IN `cloud/`, pinned by a run
  rather than quoted from a comment — and it is NOT the same truth as `api/`'s.

  `api/` swept this folklore and landed
  `api/test/barkpark/casterror_status_contract_test.exs`, which pins **400**.
  That answer is correct THERE and wrong HERE, because the two apps do not
  share a dependency set:

    * `api/` is Phoenix and carries `phoenix_ecto`, whose
      `phoenix_ecto/lib/phoenix_ecto/plug.ex` opens with
      `{Ecto.CastError, 400}, {Ecto.Query.CastError, 400}` and derives a
      `Plug.Exception` impl for each. Hence 400 in `api/`.

    * `cloud/` is deliberately NOT Phoenix — `cloud/mix.exs` builds the
      control plane on `Plug.Router` + `Bandit`, and `cloud/mix.lock` has no
      `phoenix_ecto` entry at all. Across every one of cloud's deps, the ONLY
      file defining a `Plug.Exception` impl is
      `plug/lib/plug/exceptions.ex`, whose `for: Any` clause ends
      `def status(_), do: 500`. `ecto` itself defines no `Plug.Exception`
      impl and stamps no `plug_status` field on either struct
      (`ecto/lib/ecto/exceptions.ex`: `Ecto.Query.CastError` is
      `defexception [:type, :value, :message]`, `Ecto.CastError` is
      `defexception [:message, :type, :value]`).

  So in `cloud/`, a `CastError` of EITHER module that escapes to Plug really
  does answer **500**. The "-> 500" half of the folklore is TRUE here; only
  the MODULE half can be wrong, and only on the query path:

    * Binding a non-castable binary to a `:binary_id` column raises
      `%Ecto.Query.CastError{}`. `Ecto.CastError` is a different struct and
      fires ZERO times on that path, so an `assert_raise Ecto.CastError`
      written from the old wording can never match — it would look like a
      guard test and pin nothing.

    * `Ecto.CastError` DOES genuinely fire on the changeset/cast path —
      `ecto/lib/ecto/changeset.ex` raises it for "a map with mixed keys" —
      so naming it there is correct, not folklore.

  The live risk this file guards is therefore the OPPOSITE of api's: someone
  copies the api sweep's "CastError -> 400" into `cloud/`, where nothing maps
  it to 400. Arm 3 reds on exactly that.

  Every arm carries its own control, so a green here is a green with a
  subject.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Registry.Barkpark

  @garbage "not-a-uuid"

  describe "the exception module" do
    test "Ecto.Query.CastError and Ecto.CastError are different modules" do
      refute Ecto.Query.CastError == Ecto.CastError
    end

    test "binding a non-UUID to a :binary_id column raises Ecto.Query.CastError, never Ecto.CastError" do
      err =
        assert_raise Ecto.Query.CastError, fn ->
          Repo.one(from(b in Barkpark, where: b.id == ^@garbage, select: b.id))
        end

      # CONTROL: name the struct explicitly. `assert_raise` alone would also
      # pass on a rescue-shaped match; this pins the exact module.
      assert err.__struct__ == Ecto.Query.CastError
      refute err.__struct__ == Ecto.CastError
    end

    test "CONTROL: a well-formed but absent UUID does NOT raise — the raise is about the CAST" do
      absent = Ecto.UUID.generate()
      assert Repo.one(from(b in Barkpark, where: b.id == ^absent, select: b.id)) == nil
    end
  end

  describe "the HTTP status cloud/ maps it to (no phoenix_ecto here)" do
    test "cloud has NO Plug.Exception impl for either CastError — both fall through to Any" do
      # This is the dependency fact the whole file rests on, asserted against
      # the protocol's own dispatch rather than against a comment. If someone
      # ever adds phoenix_ecto to cloud/mix.exs, THIS is the arm that reds and
      # sends them back to update every comment in cloud/.
      assert Plug.Exception.impl_for(%Ecto.Query.CastError{}) == Plug.Exception.Any
      assert Plug.Exception.impl_for(%Ecto.CastError{}) == Plug.Exception.Any
    end

    test "Ecto.Query.CastError is 500 in cloud/, NOT the 400 api/ answers" do
      err =
        assert_raise Ecto.Query.CastError, fn ->
          Repo.one(from(b in Barkpark, where: b.id == ^@garbage, select: b.id))
        end

      assert Plug.Exception.status(err) == 500
      refute Plug.Exception.status(err) == 400
    end

    test "Ecto.CastError is ALSO 500 here — the status is the same for either module" do
      # Run-measured, not constructed: `Ecto.UUID.cast!/1` is where
      # `Ecto.CastError` genuinely DOES fire (the cast!/changeset path, never
      # a query bind).
      err = assert_raise Ecto.CastError, fn -> Ecto.UUID.cast!(nil) end

      assert err.__struct__ == Ecto.CastError
      assert Plug.Exception.status(err) == 500
    end

    test "CONTROL: Plug.Exception.status/1 does not answer 500 for everything" do
      # Without this, the 500s above would also pass against a dead protocol.
      # Plug's own exceptions carry `plug_status`, so the Any clause's FIRST
      # head (`%{plug_status: status}`) answers something other than 500.
      assert Plug.Exception.status(%Plug.Parsers.ParseError{
               exception: %RuntimeError{message: "boom"}
             }) == 400

      # and the fallback really is the one answering for the CastErrors
      assert Plug.Exception.status(%RuntimeError{message: "boom"}) == 500
    end
  end

  describe "the api/ answer cannot be copied into cloud/" do
    # A comment fix changes nothing that can red. THIS is the arm that reds:
    # it re-derives the census on every run instead of trusting a snapshot.
    #
    # RULE (a predicate, not a list): inside cloud/lib and cloud/test, a line
    # that mentions CastError and 400 in the same breath is asserting api/'s
    # phoenix_ecto mapping in a tree that has no phoenix_ecto. The only lines
    # allowed to pair them are ones explicitly talking ABOUT the difference.
    @justifiers ~w(phoenix_ecto api/ NOT never wrong Parsers)

    @roots ~w(lib test)

    defp folklore_offenders(predicate) do
      Enum.flat_map(@roots, fn root ->
        dir = Path.join(File.cwd!(), root)

        dir
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "casterror_status_contract_test.exs"))
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} -> predicate.(line) end)
          |> Enum.map(fn {line, n} ->
            "#{root}/#{Path.relative_to(file, dir)}:#{n}: #{String.trim(line)}"
          end)
        end)
      end)
    end

    defp folklore_line?(line) do
      String.contains?(line, "CastError") and
        String.contains?(line, "400") and
        not Enum.any?(@justifiers, &String.contains?(line, &1))
    end

    test "no cloud/ comment claims a CastError -> 400 mapping" do
      offenders = folklore_offenders(&folklore_line?/1)

      assert offenders == [],
             """
             These cloud/ lines assert a "CastError -> 400" mapping. That is
             api/'s answer and it comes from `phoenix_ecto`, which cloud/ does
             NOT depend on (cloud/mix.exs is Plug.Router + Bandit; the only
             Plug.Exception impl in cloud's deps is plug's `for: Any`, which
             answers 500). Say 500, or name phoenix_ecto/api explicitly:

             #{Enum.join(offenders, "\n")}
             """
    end

    test "CONTROL: the sweep above can actually SEE a violation, and its corpus is non-empty" do
      # Without this arm the previous test would stay green if the wildcard,
      # the read, or the predicate silently matched nothing.
      folklore = "# a non-UUID id would raise Ecto.CastError → 400 here."
      assert folklore_line?(folklore)

      # a near-miss must NOT trip it, or the guard is just a CastError grep
      refute folklore_line?("# raises Ecto.Query.CastError → 500 (Plug's Any fallback).")

      files =
        Enum.flat_map(@roots, &Path.wildcard(Path.join([File.cwd!(), &1, "**/*.{ex,exs}"])))

      assert length(files) > 100, "the cloud/ corpus scanned was #{length(files)} files"

      # and the corpus genuinely contains CastError lines to discriminate among
      hits = folklore_offenders(&String.contains?(&1, "CastError"))
      assert length(hits) > 10, "only #{length(hits)} CastError lines found in the corpus"
    end
  end
end
