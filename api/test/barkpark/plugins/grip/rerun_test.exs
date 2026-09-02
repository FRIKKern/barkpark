defmodule Barkpark.Plugins.Grip.RerunTest do
  @moduledoc """
  The `rerun` grammar in isolation — the ladder, the ceiling and the
  fail-closed screen. Pure: no DB, no plugin registry, no dispatcher.

  What each block is buying:

    * **the ladder** — one honest command per rung, plus the two shapes the
      Node grammar records as its OWN past failures (a bracketed-IPv6 loopback
      url falsely promoted to L1; an `ssh` with flags before the `@` falsely
      demoted from L1).
    * **evidence is L6 by construction** — the grammar must not read the
      narrative fields. The only way to assert that from outside is to hand it
      a command whose PROSE screams L1 and check the level stays where the
      INVOCATION puts it.
    * **the ceiling** — able to refuse (a claim above), able to pass (equal),
      able to under-claim (below).
    * **the screen** — each of its four refusal codes, and an admission.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Grip.Rerun

  describe "derive_level/1 — the ladder" do
    test "L1: an ssh read of a running host" do
      assert Rerun.derive_level("ssh root@89.167.28.206 'systemctl is-active barkpark'") == "L1"
    end

    test "L1: flags between ssh and the user@host do not demote" do
      # The Node grammar's own recorded failure: an adjacency regex
      # false-demoted a genuine `ssh -o BatchMode=yes … root@…` read.
      assert Rerun.derive_level("ssh -o BatchMode=yes -i ~/.ssh/k root@example.com uptime") ==
               "L1"
    end

    test "L1: a curl to a non-loopback host" do
      assert Rerun.derive_level("curl -s https://api.barkpark.cloud/api/schemas") == "L1"
    end

    test "L3: a loopback curl reads the LOCAL dev system, not a running system" do
      assert Rerun.derive_level("curl -s http://localhost:4000/api/schemas") == "L3"
    end

    test "L3: a BRACKETED IPv6 loopback is normalised, not read as host `[`" do
      # The naive host pattern stops at the first colon and captures a bare
      # `[`, which fails the loopback test and FALSELY PROMOTES this to L1.
      assert Rerun.derive_level("curl -s http://[::1]:4000/api/schemas") == "L3"
    end

    test "L2: git show against a remote ref" do
      assert Rerun.derive_level("git show origin/main:api/mix.exs") == "L2"
    end

    test "L3: git show against the local object store is NOT L2" do
      assert Rerun.derive_level("git show HEAD:api/mix.exs") == "L3"
    end

    test "L2: gh api, and a bare remote-API client" do
      assert Rerun.derive_level("gh api repos/FRIKKern/barkpark/pulls/14383") == "L2"
      assert Rerun.derive_level("bp task get tgw10-bl-server-side-type-fact-hook -o json") == "L2"
    end

    test "L3: a URL-free local `bp scaffy` verb touches only the cwd tree" do
      assert Rerun.derive_level("bp scaffy validate x.scaffy") == "L3"
    end

    test "L2: `scaffy` as an ARGUMENT is not a scaffy verb" do
      # A bare membership test matches the word anywhere and OVER-DEMOTES a
      # genuine remote read L2→L3, making the ceiling refuse an honest claim.
      assert Rerun.derive_level("bp task get scaffy validate x.scaffy") == "L2"
    end

    test "L3: local reads, scoped grep and local test runs" do
      assert Rerun.derive_level("grep -rn 'before_publish' api/lib/barkpark/plugins") == "L3"
      assert Rerun.derive_level("CC=clang mix test test/barkpark/plugins/grip") == "L3"
      assert Rerun.derive_level("node tooling/grip/ledger.mjs fold") == "L3"
    end

    test "L4: a read whose TARGET is a known generated artifact" do
      assert Rerun.derive_level("jq '.paths | length' docs/openapi.json") == "L4"
    end

    test "L4: an artifact read piped to a local consumer stays an artifact read" do
      assert Rerun.derive_level("cat docs/openapi.json | jq .") == "L4"
    end

    test "L6: no command at all" do
      assert Rerun.derive_level("") == "L6"
      assert Rerun.derive_level(nil) == "L6"
    end

    test "L6: a shape the grammar cannot classify demotes, it does not raise" do
      assert Rerun.derive_level("frobnicate --all --please") == "L6"
    end

    test "the STRONGEST segment wins — a wrapper cannot cap a remote read" do
      # `cd /opt && curl https://prod/health` reaches production; the derived
      # level is a CEILING on what the compound could have observed.
      assert Rerun.derive_level("cd /opt/barkpark && curl -s https://api.example.com/health") ==
               "L1"

      # …and a pipe consumer must not demote its producer.
      assert Rerun.derive_level("curl -s https://api.example.com/x | jq .count") == "L1"
    end
  end

  describe "derive_level/1 — mention is not invocation" do
    test "a quoted production command under a reader head is a MENTION" do
      assert Rerun.derive_level("grep -rn 'ssh root@prod' docs/ops") == "L3"
    end

    test "an UNQUOTED production command under a reader head is still a mention" do
      assert Rerun.derive_level("grep -rn ssh root@prod docs/ops") == "L3"
    end

    test "a process substitution under a reader head IS a real invocation" do
      assert Rerun.derive_level("diff <(git show origin/main:api/mix.exs) api/mix.exs") == "L2"
    end

    test "the evidence prose can never raise the level — the grammar never sees it" do
      # The refuted prose scanner stamped L1 on strings like this one. Here the
      # narrative lives inside the command's own quoted argument, which is the
      # closest a caller can get to handing the grammar an evidence string.
      command = "cat 'ran ssh root@prod and curl https://prod/health — verified live' api/mix.exs"
      assert Rerun.derive_level(command) == "L3"
    end
  end

  describe "derive_level/1 — the parseability floor" do
    test "a template slot is not a runnable command" do
      assert Rerun.derive_level("git show origin/main:<path>") == "L6"
      assert Rerun.derive_level("bp onramp windsurf --write [--force]") == "L6"
    end

    test "an elision is not a runnable command" do
      assert Rerun.derive_level("grep -rn foo api/lib ... then read the hits") == "L6"
    end

    test "slash-joined numbers are shorthand for several commands" do
      assert Rerun.derive_level("gh pr view 4631/4632/4633") == "L6"
    end

    test "a prose aside in parentheses demotes" do
      assert Rerun.derive_level("bp sites -o json | python3 (count)") == "L6"
    end

    test "a real subshell opening on a known head is left alone" do
      assert Rerun.derive_level("(cd api && mix test test/x_test.exs)") == "L3"
    end
  end

  describe "check_ceiling/2" do
    test "REFUSES a claim above the derived level, naming both" do
      assert {:error, message} = Rerun.check_ceiling("L1", "L3")
      assert message =~ "LEVEL-SKIP"
      assert message =~ "claimed L1"
      assert message =~ "derived L3"
    end

    test "ACCEPTS a claim equal to the derived level" do
      assert Rerun.check_ceiling("L3", "L3") == :ok
    end

    test "ACCEPTS an honest under-claim" do
      assert Rerun.check_ceiling("L6", "L1") == :ok
    end

    test "refuses a rung that is not on the ladder" do
      assert {:error, message} = Rerun.check_ceiling("L0", "L3")
      assert message =~ "UNKNOWN-LEVEL"

      assert {:error, nil_message} = Rerun.check_ceiling(nil, "L3")
      assert nil_message =~ "UNKNOWN-LEVEL"
    end
  end

  describe "screen/1 — fail-closed" do
    test "admits an ordinary read" do
      assert Rerun.screen("grep -rn 'before_publish' api/lib") == :ok
      assert Rerun.screen("git show origin/main:api/mix.exs") == :ok
      assert Rerun.screen("ssh root@example.com uptime") == :ok
    end

    test "NO-RERUN: absent, blank or non-string" do
      assert {:error, blank} = Rerun.screen("   ")
      assert blank =~ "NO-RERUN"
      assert {:error, missing} = Rerun.screen(nil)
      assert missing =~ "NO-RERUN"
    end

    test "NOT-A-COMMAND: a string the floor rejects" do
      assert {:error, message} = Rerun.screen("git show origin/main:<path>")
      assert message =~ "NOT-A-COMMAND"
    end

    test "NOT-ALLOWLISTED: an unrecognised head is refused, not admitted" do
      assert {:error, message} = Rerun.screen("frobnicate --all")
      assert message =~ "NOT-ALLOWLISTED"
      assert message =~ "frobnicate"
    end

    test "NOT-ALLOWLISTED: a destructive head is refused even though the floor knows it" do
      # `rm` is on the prose floor's KNOWN_HEADS (so a real destructive command
      # is not mistaken for prose) and deliberately NOT on the screen's
      # allowlist. The two lists exist for different questions.
      assert {:error, message} = Rerun.screen("rm -rf api/_build")
      assert message =~ "NOT-ALLOWLISTED"
    end

    test "WRITE-SHAPED: an output redirect to a file is refused" do
      assert {:error, message} = Rerun.screen("grep -rn foo api/lib > hits.txt")
      assert message =~ "WRITE-SHAPED"
    end

    test "a file-descriptor dup and a /dev/null discard are NOT writes" do
      assert Rerun.screen("mix test test/x_test.exs 2>&1") == :ok
      assert Rerun.screen("grep -rn foo api/lib 2>/dev/null") == :ok
    end

    test "a `>` inside quotes is inert" do
      assert Rerun.screen("grep -n 'a > b' api/lib/barkpark.ex") == :ok
    end
  end
end
