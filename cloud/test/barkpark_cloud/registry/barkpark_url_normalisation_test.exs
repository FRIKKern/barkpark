defmodule BarkparkCloud.BarkparkUrlFold.Extract do
  @moduledoc """
  Lifts the two functions this suite composes out of their SOURCE files, as
  1-arity anonymous functions: the write-side fold `fold_url/1`
  (`registry/barkpark.ex`) and the read-side claim-host normaliser
  `normalize_claim_host/1` (`registry.ex`).

  Why the AST and not an import. Both are `defp`, and both must STAY `defp`:
  promoting a private function so a test can reach it changes the shipped
  module's public surface to serve the test. So each function's BODY is read off
  the AST and evaluated as an anonymous function — the same technique
  `registry_claim_host_normaliser_test.exs` uses for the claim-host twins, spelled
  locally here so this file runs standalone (`mix test <this file>`) without
  depending on which other test file the runner happened to load first.

  Why it matters that the READ side is lifted rather than retyped. The property
  under test is composition — `read(write(x)) == read(x)` — and a hand-copied
  read-side normaliser would be a fourth implementation, free to agree with a
  stale idea of the shipped one and certify a divergence as parity.

  `without_separator_guard/1` rewrites the write-side SOURCE back to its
  pre-remedy shape (trailing slashes stripped from the WHOLE string, scheme
  separator included), so the composition arm can be shown to LOSE.
  """

  @doc "The write-side fold `fold_url/1` from `registry/barkpark.ex`."
  @spec write_fold(binary) :: (binary -> binary)
  def write_fold(source) when is_binary(source), do: lift(source, :fold_url, 1)

  @doc "The read-side normaliser `normalize_claim_host/1` from `registry.ex`."
  @spec claim_host(binary) :: (binary -> binary)
  def claim_host(source) when is_binary(source), do: lift(source, :normalize_claim_host, 1)

  @doc """
  MUTATION: the write-side fold with its separator preservation removed — the
  pre-remedy shape, which trimmed trailing slashes off the whole string and so
  ate the `://` of a scheme-only url.
  """
  @spec without_separator_guard(binary) :: binary
  def without_separator_guard(source) when is_binary(source) do
    pattern = ~s|String.split(trimmed, "://", parts: 2)|
    replacement = ~s|String.split(String.trim_trailing(trimmed, "/"), "://", parts: 2)|

    case String.split(source, pattern) do
      [before, rest] ->
        before <> replacement <> rest

      parts ->
        raise "expected exactly one #{inspect(pattern)} in the source, found " <>
                "#{length(parts) - 1} — did `fold_url/1` get rewritten? This mutation " <>
                "arm then proves nothing."
    end
  end

  defp lift(source, name, arity) do
    {arg, body} = fun_ast(source, name, arity)
    {fun, _} = Code.eval_quoted({:fn, [], [{:->, [], [[{arg, [], nil}], body]}]})
    fun
  end

  # The def/defp argument name and body for name/arity. `:when`-guarded heads are
  # unwrapped: an AST match that forgets to is silently blind to every guarded
  # clause — and `normalize_url/1`'s binary head IS guarded.
  defp fun_ast(source, name, arity) do
    {_, found} =
      source
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Macro.prewalk(nil, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_sig(head) do
            {^name, ^arity, arg} -> {node, {arg, Keyword.fetch!(body, :do)}}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found || raise "#{name}/#{arity} not found — did it get renamed or deleted?"
  end

  defp head_sig({:when, _, [head | _]}), do: head_sig(head)

  defp head_sig({name, _, [{arg, _, nil} | _] = args}) when is_atom(name) and is_atom(arg),
    do: {name, length(args), arg}

  defp head_sig(_), do: nil
end

defmodule BarkparkCloud.Registry.BarkparkUrlNormalisationTest do
  @moduledoc """
  cch-w69 D852 — the worker route stops storing hostile `:url` spellings.

  `POST /v1/internal/barkparks` (Auth.require_worker) stored `conn.body_params["url"]`
  VERBATIM into `Barkpark.changeset/2`: `:url` was cast with no `validate_format`,
  and `barkparks_url_unique_idx` sits on the RAW column — so ` https://h` and
  `https://h` were two distinct rows for one hostname, and every other reader
  (`subdomain_from_url/1`, DomainStatus.platform_host/1) had to re-derive the trim
  or diverge again. These tests pin normalise-on-write at that single chokepoint:
  trim (space/tab/NBSP/CRLF) + downcase + strip the trailing slash, keeping the
  origin form.

  ## The composition property, and why this file owns it

  The fold is a THIRD normaliser standing beside the claim-walk twins that
  #11785 built a 707-line census for, so it owes them
  `normalize_claim_host(normalize_url(x)) == normalize_claim_host(x)`: if that
  holds, a write fold can never make a host stop matching its own claim (`:free`
  for a live box) nor start matching another tenant's. The first shape of this
  fold BROKE it for one class. `String.trim_trailing(url, "/")` over the whole
  string ate the scheme separator, so `"https://"` stored as `"https:"`; the read
  side's scheme regex is anchored on `://`, stopped recognising the scheme, fell
  through to its "cut at the first non-hostname character" step and answered
  `"https"` — the SCHEME LABEL as a hostname — where the same input read `""`
  before the fold. Not cross-tenant exploitable (the phantom is always the
  literal scheme label, never another tenant's host, and a bare label is not a
  provisionable FQDN) but a changed claim-walk answer, i.e. exactly the
  step-added-to-one-twin divergence #11785 exists to prevent. `describe "the
  scheme separator survives the fold"` pins the class; `describe "composition
  with the read-side claim-host normaliser"` pins the property over the whole
  corpus and proves it can LOSE by rebuilding the pre-remedy fold from source.

  ## What the fold does NOT close

  Whitespace, case and the trailing slash, and nothing else. Trailing dot, scheme
  variance, port and path all survive it, so `barkparks_url_unique_idx` still
  admits six distinct rows for the one claim host `gyldendal.barkpark.cloud` —
  the index is NARROWED, not made canonical, and the defense-in-depth backstop
  stays bypassable by those spellings (`describe "what the fold leaves
  standing"`).

  HONESTY CLAUSE (also carried in the `normalize_url/1` comment the merge ships):
  this is NEW-WRITES-ONLY. It does not backfill existing rows and does not
  strengthen the raw-column unique index into an expression index — the backfill
  (with its prod dup-scan) is owned by
  `cch-w70-bl-worker-url-backfill-gated-on-prod-dup-scan`. A collision the scan
  misses is not a 500: `unique_constraint(:url, name: :barkparks_url_unique_idx)`
  is already declared on the changeset, so a normalisation collision degrades to
  `{:error, changeset}` and a clean 422.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.BarkparkUrlFold.Extract
  alias BarkparkCloud.Registry.Barkpark

  @write_source Path.expand("../../../lib/barkpark_cloud/registry/barkpark.ex", __DIR__)
  @read_source Path.expand("../../../lib/barkpark_cloud/registry.ex", __DIR__)

  # Every `:url` spelling the wave's threat model names, plus the degenerate ones.
  # Drives both the composition property and the idempotence arm.
  @corpus [
    "https://gyldendal.barkpark.cloud",
    "https://gyldendal-71069eaa.barkpark.cloud",
    " https://gyldendal.barkpark.cloud",
    "https://gyldendal.barkpark.cloud ",
    "\thttps://gyldendal.barkpark.cloud",
    "https://gyldendal.barkpark.cloud\r\n",
    "\r\n\thttps://gyldendal.barkpark.cloud  ",
    " https://gyldendal.barkpark.cloud",
    "HTTPS://Gyldendal.Barkpark.Cloud",
    "HTTPS://GYLDENDAL.BARKPARK.CLOUD",
    " HTTPS://Gyldendal.Barkpark.Cloud/ ",
    "https://gyldendal.barkpark.cloud/",
    "https://gyldendal.barkpark.cloud//",
    "https://gyldendal.barkpark.cloud///",
    "https://gyldendal.barkpark.cloud.",
    "https://gyldendal.barkpark.cloud:4000",
    "https://gyldendal.barkpark.cloud:4000/",
    "https://gyldendal.barkpark.cloud/studio",
    "https://gyldendal.barkpark.cloud/studio/",
    "http://gyldendal.barkpark.cloud",
    "gyldendal.barkpark.cloud",
    "gyldendal.barkpark.cloud/",
    "a.barkpark.cloud.evil.example",
    "https://",
    "HTTPS://",
    "http://",
    "ftp://",
    "https:///",
    "https:////",
    "/",
    "//",
    "///"
  ]

  defp write_fold, do: Extract.write_fold(File.read!(@write_source))
  defp claim_host, do: Extract.claim_host(File.read!(@read_source))

  # The changeset only reports a `:url` change when the cast+normalised value
  # differs from the struct's current value; build against a bare struct so any
  # stored url surfaces in `changes`.
  defp normalised_url(input) do
    %Barkpark{}
    |> Barkpark.changeset(%{
      name: "BP",
      slug: "bp",
      team_id: "00000000-0000-0000-0000-000000000000",
      url: input
    })
    |> Ecto.Changeset.get_change(:url)
  end

  describe "Barkpark.changeset/2 normalises :url on write" do
    test "leading/trailing ASCII space is trimmed" do
      # PRE-FIX bytes: the verbatim store kept the leading space, so this asserted
      # value would have been " https://gyldendal.barkpark.cloud".
      assert normalised_url(" https://gyldendal.barkpark.cloud") ==
               "https://gyldendal.barkpark.cloud"

      assert normalised_url("https://gyldendal.barkpark.cloud ") ==
               "https://gyldendal.barkpark.cloud"
    end

    test "leading tab / NBSP / CRLF whitespace is trimmed" do
      assert normalised_url("\thttps://h.barkpark.cloud") == "https://h.barkpark.cloud"
      assert normalised_url(" https://h.barkpark.cloud") == "https://h.barkpark.cloud"
      assert normalised_url("https://h.barkpark.cloud\r\n") == "https://h.barkpark.cloud"

      assert normalised_url("\r\n\thttps://h.barkpark.cloud  ") ==
               "https://h.barkpark.cloud"
    end

    test "mixed-case scheme/host is downcased" do
      # PRE-FIX: stored verbatim as "HTTPS://Gyldendal.Barkpark.Cloud".
      assert normalised_url("HTTPS://Gyldendal.Barkpark.Cloud") ==
               "https://gyldendal.barkpark.cloud"
    end

    test "a trailing slash is stripped (origin form)" do
      # PRE-FIX: stored verbatim as "https://h.barkpark.cloud/".
      assert normalised_url("https://h.barkpark.cloud/") == "https://h.barkpark.cloud"
      # multiple trailing slashes collapse too
      assert normalised_url("https://h.barkpark.cloud//") == "https://h.barkpark.cloud"
    end

    test "the whitespace/case/trailing-slash class collapses to one canonical form" do
      canonical = "https://gyldendal.barkpark.cloud"

      hostile = [
        " HTTPS://Gyldendal.Barkpark.Cloud/ ",
        "\thttps://GYLDENDAL.barkpark.cloud",
        " https://gyldendal.barkpark.cloud/\r\n"
      ]

      for spelling <- hostile do
        assert normalised_url(spelling) == canonical,
               "hostile spelling #{inspect(spelling)} did not normalise"
      end
    end
  end

  describe "clean rows pass through unchanged" do
    test "an already-normalised clean_url/1 value is byte-identical" do
      clean = Barkpark.clean_url("gyldendal")
      assert clean == "https://gyldendal.barkpark.cloud"

      # A clean value is not even reported as a change off a struct that already
      # holds it — nothing to rewrite.
      changeset =
        %Barkpark{url: clean}
        |> Barkpark.changeset(%{name: "BP", slug: "gyldendal", team_id: "x", url: clean})

      assert Ecto.Changeset.get_change(changeset, :url) == nil

      # And normalising a fresh clean write leaves it byte-identical.
      assert normalised_url(clean) == clean
    end

    test "a suffixed provisioning url passes through byte-identical" do
      suffixed = "https://gyldendal-71069eaa.barkpark.cloud"
      assert normalised_url(suffixed) == suffixed
    end
  end

  describe "the scheme separator survives the fold" do
    test "a scheme-only url keeps its ://" do
      # The first shape of this fold trimmed trailing slashes off the WHOLE
      # string, so each of these stored with the separator eaten ("https:",
      # "http:", "ftp:") and the read side then answered with the scheme LABEL as
      # a hostname. The separator is data, not a trailing slash.
      assert normalised_url("https://") == "https://"
      assert normalised_url("HTTPS://") == "https://"
      assert normalised_url("http://") == "http://"
      assert normalised_url("ftp://") == "ftp://"
      assert normalised_url("https:///") == "https://"
      assert normalised_url("https:////") == "https://"
    end

    test "slashes after the separator still collapse" do
      assert normalised_url("https://h.barkpark.cloud///") == "https://h.barkpark.cloud"

      assert normalised_url("https://h.barkpark.cloud/studio/") ==
               "https://h.barkpark.cloud/studio"
    end

    test "a slash-only url is left exactly as it arrived, never folded to \"\"" do
      # "" IS indexed — barkparks_url_unique_idx is partial on WHERE url IS NOT
      # NULL and '' is not NULL — so a fold that emptied these would hand the
      # first junk write a GLOBAL claim on '' and the next team's write a 422.
      assert normalised_url("/") == "/"
      assert normalised_url("//") == "//"
      assert normalised_url("///") == "///"
    end

    test "whitespace-only input never reaches the fold at all" do
      # Ecto's cast/3 treats a whitespace-only string as an empty value and drops
      # the change, so :url stays nil rather than becoming ''.
      assert normalised_url("   ") == nil
      assert normalised_url("\t\r\n") == nil
    end
  end

  describe "composition with the read-side claim-host normaliser" do
    test "read(write(x)) == read(x) for every corpus spelling" do
      read = claim_host()

      for input <- @corpus do
        stored = normalised_url(input) || input

        assert read.(stored) == read.(input),
               """
               the write fold CHANGED a claim-walk answer for #{inspect(input)}:
                 stored as      #{inspect(stored)}
                 read(write(x)) #{inspect(read.(stored))}
                 read(x)        #{inspect(read.(input))}
               """
      end
    end

    test "the fold never merges two distinct claim hosts" do
      read = claim_host()

      distinct = [
        {"https://a.barkpark.cloud", "https://b.barkpark.cloud"},
        {"https://gyldendal.barkpark.cloud", "https://gyldendal-71069eaa.barkpark.cloud"},
        {"https://a.barkpark.cloud", "https://a.barkpark.cloud.evil.example"}
      ]

      for {left, right} <- distinct do
        refute read.(normalised_url(left)) == read.(normalised_url(right))
      end
    end

    test "the fold is idempotent" do
      for input <- @corpus do
        once = normalised_url(input) || input
        assert normalised_url(once) == once or normalised_url(once) == nil
      end
    end

    test "MUTATION: the pre-remedy fold breaks the property, so the arm can lose" do
      mutant = @write_source |> File.read!() |> Extract.without_separator_guard()
      fold = Extract.write_fold(mutant)
      read = claim_host()

      # Reconstructed from source rather than remembered from a transcript: the
      # pre-remedy fold ate the separator and moved the claim answer from "" to
      # the scheme label.
      assert fold.("https://") == "https:"
      assert read.("https://") == ""
      assert read.(fold.("https://")) == "https"

      diverging =
        Enum.filter(@corpus, fn input -> read.(fold.(input)) != read.(input) end)

      assert "https://" in diverging,
             "the mutation no longer breaks composition — this arm proves nothing"

      # And the shipped fold has no such class.
      shipped = write_fold()

      assert Enum.filter(@corpus, fn input ->
               read.(normalised_url(input) || input) != read.(input)
             end) == []

      assert shipped.("https://") == "https://"
    end
  end

  describe "what the fold leaves standing" do
    test "six spellings of one claim host still store as six distinct rows" do
      # The fold NARROWS barkparks_url_unique_idx; it does not make it canonical.
      # These six differ by trailing dot, scheme, port, path and bare-host — none
      # of which the fold touches — so the raw-column index still admits all six
      # while the read side maps them onto one claim host.
      six = [
        "https://gyldendal.barkpark.cloud",
        "https://gyldendal.barkpark.cloud.",
        "http://gyldendal.barkpark.cloud",
        "https://gyldendal.barkpark.cloud/studio",
        "https://gyldendal.barkpark.cloud:4000",
        "gyldendal.barkpark.cloud"
      ]

      stored = Enum.map(six, &normalised_url/1)
      assert stored == six, "the fold now touches one of these — update the claim above"
      assert Enum.uniq(stored) |> length() == 6

      read = claim_host()
      assert Enum.map(six, &read.(&1)) |> Enum.uniq() == ["gyldendal.barkpark.cloud"]
    end
  end
end
