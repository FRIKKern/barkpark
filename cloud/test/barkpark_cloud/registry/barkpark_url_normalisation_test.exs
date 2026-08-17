defmodule BarkparkCloud.Registry.BarkparkUrlNormalisationTest do
  @moduledoc """
  cch-w69 D852 — the worker route stops storing hostile `:url` spellings.

  `POST /v1/internal/barkparks` (Auth.require_worker) stored `conn.body_params["url"]`
  VERBATIM into `Barkpark.changeset/2`: `:url` was cast with no `validate_format`,
  and `barkparks_url_unique_idx` sits on the RAW column — so ` https://h` and
  `https://h` were two distinct rows for one hostname, and every other reader
  (`subdomain_from_url/1`, DomainStatus.platform_host/1) had to re-derive the trim
  or diverge again. These tests pin normalise-on-write at that single chokepoint:
  trim (space/tab/NBSP/CRLF) + downcase + strip trailing slash, keeping the origin
  form.

  HONESTY CLAUSE (also carried in the `normalize_url/1` comment the merge ships):
  this is NEW-WRITES-ONLY. It does not backfill existing rows and does not
  strengthen the raw-column unique index into an expression index — the backfill
  (with its prod dup-scan) is owned by
  `cch-w70-bl-worker-url-backfill-gated-on-prod-dup-scan`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.Barkpark

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

    test "the whole hostile class collapses to one canonical form" do
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
end
