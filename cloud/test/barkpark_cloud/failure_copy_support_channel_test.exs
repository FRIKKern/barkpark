defmodule BarkparkCloud.FailureCopySupportChannelTest do
  @moduledoc """
  cch-w50-s2 — THERE IS NO SUPPORT DESK, so no copy this module emits may name
  one.

  This deployment has no customer-support channel of any kind: no address, no
  inbox, no route, no docs page, no nav link, no SLA. `grep -riE
  "support@|mailto:|/support|SUPPORT_EMAIL"` over `cloud/lib`,
  `cloud/priv/static/app.js` and `cloud/priv/static/index.html` returns zero
  customer-facing hits — every match is `POST /v1/fleet/supports` or
  `/v1/internal/support-jobs/claim`, i.e. SUPPORT MACHINES, a fleet server role.
  The plane's only mail identity is `noreply@barkpark.cloud`, with no `reply_to`.

  The epic had already ruled on this and enforced it in exactly one place:
  `domain_status_test.exs` refutes the phrase on the CUSTOM pointing arm only,
  while the PLATFORM arm right above it kept shipping "…re-attach the domain or
  contact support." A per-arm refutation cannot see the arm next door — this file
  is the ban that can.

  It is a NEW file on purpose (charter D568): the wave's other slices are editing
  `failure_copy_test.exs` and `domain_status_test.exs` neighbourhoods, and a ban
  wants to contend with nothing in place.

  TWO LAYERS, because either alone is a false green:

    1. DRIVEN — every copy-emitting arm of `FailureCopy`, over the full input
       matrix each one branches on. This is what a person actually reads.
    2. SOURCE — every string literal in the module's CODE (doc blocks excluded,
       since the moduledoc for `domain_stage_remediation/2` legitimately QUOTES
       the retired sentence as history). The driven sweep cannot reach
       `classify/1`'s private mapping table; this can, and it also catches a new
       arm added without a driven case.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.FailureCopy

  @ban ~r/contact support/i

  # The kinds and stages `DomainStatus` actually produces, plus an unknown kind
  # and an unknown stage so the catch-all clauses are swept too.
  @kinds ~w(platform custom something_new)
  @stages ~w(dns_found points_here tls serving anything_new)
  @providers ~w(hetzner azure cloudflare something_new)
  @capabilities ~w(adopt pause catalog lifecycle labels core dns something_new)

  describe "the driven sweep: no emitted copy names a support channel" do
    test "domain_stage_remediation/2 across every (kind, stage)" do
      for kind <- @kinds, stage <- @stages do
        copy = FailureCopy.domain_stage_remediation(kind, stage)

        assert is_binary(copy) and copy != ""

        refute copy =~ @ban,
               "domain_stage_remediation(#{inspect(kind)}, #{inspect(stage)}) offers a support " <>
                 "channel this deployment does not have: #{copy}"
      end
    end

    test "connect_remediation/1 and provider_not_connected_remediation/1 across every provider" do
      for provider <- @providers do
        for {label, copy} <- [
              {"connect_remediation", FailureCopy.connect_remediation(provider)},
              {"provider_not_connected_remediation",
               FailureCopy.provider_not_connected_remediation(provider)}
            ] do
          assert is_binary(copy) and copy != ""

          refute copy =~ @ban,
                 "#{label}(#{inspect(provider)}) offers a support channel this deployment " <>
                   "does not have: #{copy}"
        end
      end
    end

    test "capability_gap_reason/2 across every (kind, capability)" do
      for kind <- @kinds, capability <- @capabilities do
        copy = FailureCopy.capability_gap_reason(kind, capability)

        assert is_binary(copy) and copy != ""

        refute copy =~ @ban,
               "capability_gap_reason(#{inspect(kind)}, #{inspect(capability)}) offers a " <>
                 "support channel this deployment does not have: #{copy}"
      end
    end
  end

  describe "the source sweep: the phrase is absent from the module's code" do
    test "no string literal outside a doc block carries it" do
      offenders =
        "lib/barkpark_cloud/failure_copy.ex"
        |> Path.expand(File.cwd!())
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> strip_doc_blocks()
        |> strip_comments()
        |> Enum.filter(fn {line, _n} -> line =~ @ban end)

      assert offenders == [],
             "failure_copy.ex names a support channel that does not exist:\n" <>
               Enum.map_join(offenders, "\n", fn {line, n} -> "  :#{n} #{String.trim(line)}" end)
    end

    test "THE SOURCE SWEEP CAN LOSE: it sees a code line and ignores prose about it" do
      # Its own losability, proven on synthetic input rather than by editing the
      # module — a guard whose scanner is wrong is a guard that cannot fail.
      # Doc blocks and `#` comments are excluded because neither is EMITTED: the
      # moduledoc here quotes the retired sentence as history, and the comment
      # above the fixed arm records what was removed. Neither can reach a person.
      offenders =
        [
          ~s(  @moduledoc """),
          ~s(  The retired copy said "re-attach the domain or contact support".),
          ~s(  """),
          ~s(  # cch-w50-s2 — "or contact support" removed from the arm below.),
          ~s(  def a, do: "no channel named here"),
          ~s(  def b, do: "if it persists, contact support.")
        ]
        |> Enum.with_index(1)
        |> strip_doc_blocks()
        |> strip_comments()
        |> Enum.filter(fn {line, _n} -> line =~ @ban end)

      assert [{_line, 6}] = offenders,
             "the scanner must flag the emitted string (6) and neither the doc (2) nor the comment (4)"
    end
  end

  # Drop every line inside a `"""` heredoc (@moduledoc/@doc), including its
  # delimiters. A doc block may legitimately quote retired copy as history —
  # nobody reads it as an offer of help — and the module's own moduledoc does.
  defp strip_doc_blocks(numbered_lines) do
    {kept, _in_doc} =
      Enum.reduce(numbered_lines, {[], false}, fn {line, n}, {acc, in_doc?} ->
        delimiters = line |> String.split(~s(""")) |> length() |> Kernel.-(1)
        toggles? = rem(delimiters, 2) == 1

        cond do
          in_doc? and toggles? -> {acc, false}
          in_doc? -> {acc, true}
          toggles? -> {acc, true}
          true -> {[{line, n} | acc], false}
        end
      end)

    Enum.reverse(kept)
  end

  # A `#` comment is not emitted either — the fixed arm carries one naming the
  # clause it lost, and recording that is the opposite of offering it.
  defp strip_comments(numbered_lines) do
    Enum.reject(numbered_lines, fn {line, _n} -> String.starts_with?(String.trim(line), "#") end)
  end
end
