defmodule BarkparkCloud.FailureCopyTest do
  @moduledoc """
  Pure unit cover for FailureCopy.humanize/1 — the server-side twin of app.js
  failureCopy() (#939). Asserts the reaper + provision jargon maps to human copy,
  #939's builder strings stay consistent across surfaces, and unknown reasons
  pass through unchanged (graceful fallback).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.FailureCopy

  test "deploy reaper: no-build-source jargon → #939's exact copy (cross-surface parity)" do
    assert FailureCopy.humanize(
             "no build source (upload an artifact via `bp deploy` or connect a GitHub repo)"
           ) == "This site has no build source yet. Connect a repo or run bp deploy."
  end

  test "deploy reaper: exhausted stale builder lease → human retry copy" do
    assert FailureCopy.humanize("exceeded max deploy claim attempts (stale builder lease)") ==
             "The build didn't finish after several attempts and was stopped. Deploy again to retry."
  end

  test "provision claim/reaper: exceeded max attempts → human retry copy" do
    assert FailureCopy.humanize("exceeded max provision attempts (3)") ==
             "This didn't finish after several attempts. Try again in a moment."

    assert FailureCopy.humanize("exceeded max deprovision attempts (3)") ==
             "This didn't finish after several attempts. Try again in a moment."
  end

  test "mirrors #939's builder strings so the CLI matches the dashboard" do
    assert FailureCopy.humanize("artifact_url is empty (P6 bp deploy must populate it)") ==
             "The build source couldn't be fetched."

    assert FailureCopy.humanize("unsupported artifact scheme file://") ==
             "The build source couldn't be fetched."
  end

  test "output is idempotent under the client failureCopy() second pass" do
    once = FailureCopy.humanize("no build source (…)")
    assert FailureCopy.humanize(once) == once
  end

  # Provider-error classes (coherence arc D58) — quota/auth/dns/network jargon
  # never reaches a surface verbatim.

  test "capacity/quota jargon → human capacity copy (all casings)" do
    capacity =
      "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."

    assert FailureCopy.humanize("server type unavailable (SERVER_LIMIT_EXCEEDED)") == capacity
    assert FailureCopy.humanize("resource_unavailable: cx22 in fsn1") == capacity
    assert FailureCopy.humanize("account quota exceeded for servers") == capacity
    # lower-cased provider code still matches.
    assert FailureCopy.humanize("server_limit_exceeded") == capacity
  end

  # THE ARM'S PREDICATE CANNOT TELL A PROVIDER OR A RESOURCE, SO ITS COPY MUST
  # NOT ASSERT EITHER (wave 29). The clause at `failure_copy.ex` is a bare
  # substring test on `quota` / `server_limit_exceeded` / `resource_unavailable`
  # over a downcased string, and `humanize/1` is ARITY 1 — no call site passes a
  # provider, so nothing downstream of the predicate knows which one failed.
  #
  # THE DERIVABLE CRUELTY, DRIVEN THROUGH THE REAL CLASSIFIER: the DNS clause is
  # VERB-anchored (`hetzner dns <upsert|change-ttl|delete|resolve|list>` /
  # `hcloud zone rrset <…>`), so a zone-quota capture that carries NO producer
  # verb misses it and falls to the capacity arm. Before this wave it was
  # answered with "Hetzner ran out of SERVER capacity for this size. Try again
  # shortly or contact support." — right provider, WRONG resource, and a remedy
  # ("try again shortly") that cannot clear a zone ceiling. Restore that literal
  # and every refute below goes red.
  test "a verb-less zone-quota capture is not told it ran out of SERVER capacity" do
    raw = "hetzner dns: zone quota reached for this account"

    out = FailureCopy.humanize(raw)

    # It really does reach this arm — @dns_step is verb-anchored and misses it.
    assert out ==
             "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."

    # The two things the predicate cannot know are the two things it no longer says.
    refute out =~ ~r/ran out of server capacity/i
    refute out =~ ~r/\bHetzner\b/
    refute out =~ ~r/\bAzure\b/
  end

  test "an Azure capture with no Azure-specific token lands on the same provider-neutral copy" do
    # `humanize/1` has no provider argument at any of its four call sites, so an
    # Azure-origin bare-quota capture is INDISTINGUISHABLE from a Hetzner one
    # here. (No Azure producer in this tree emits a bare-quota string today —
    # `grep -rni 'quota|exceed' internal/cli/cloud/azure/` returns zero across
    # source, tests and all 18 fixtures — which is exactly why the fix rests on
    # the resource-blindness the tree CAN produce, not on an Azure input nobody
    # can make. This case pins the seam, not a live producer.)
    out = FailureCopy.humanize("public IP address quota reached for this subscription")

    refute out =~ ~r/\bHetzner\b/
    refute out =~ ~r/ran out of server capacity/i
  end

  test "auth/token jargon → human credentials copy" do
    auth =
      "A credential was rejected. This capture doesn't say whose credential it was — the raw error line names it."

    assert FailureCopy.humanize("hcloud: unauthorized (401)") == auth
    assert FailureCopy.humanize("provider returned invalid token") == auth
  end

  test "every REAL dns emitter → human domain copy, checked before capacity" do
    dns = "Securing the domain failed on the provider side."

    # The four shapes the tree can actually emit, each byte-faithful to its
    # producer's `fmt.Errorf` (all READ-ONLY, cited per row). The three strings
    # this test used to pin — "dns zone create failed …", "dns record update
    # failed", "dns zone quota exceeded" — were SYNTHETIC: no producer anywhere
    # emits them, so they proved only that the clause matched its own fixtures.
    emitters = [
      # internal/hetzner/dns.go:74 — hetzner dns upsert %q: %w
      ~s|hetzner dns upsert "bp-acme-ac4e1f2a.barkpark.cloud": zone not found|,
      # internal/hetzner/dns.go:137 — hetzner dns delete %q: %w
      ~s|hetzner dns delete "bp-acme-ac4e1f2a.barkpark.cloud": status 409|,
      # internal/cli/cloud/dns_cloud.go:146 — hcloud zone rrset set-records %q: %w: %s
      ~s|hcloud zone rrset set-records "bp-acme-ac4e1f2a.barkpark.cloud": exit status 1: rrset invalid|,
      # internal/cli/cloud/dns_cloud.go:169 — hcloud zone rrset delete %q: %w: %s
      ~s|hcloud zone rrset delete "bp-acme-ac4e1f2a.barkpark.cloud": exit status 1: not found|
    ]

    for raw <- emitters do
      assert FailureCopy.humanize(raw) == dns, "not classified as dns: #{raw}"
    end

    # internal/cli/cloud/dns_cloud.go:151 — change-ttl, and it carries a QUOTA
    # token: a DNS step is a DOMAIN problem, not a server-capacity one, and the
    # clause ordering is what guarantees the domain copy wins.
    assert FailureCopy.humanize(
             ~s|hcloud zone rrset change-ttl "bp-acme-ac4e1f2a.barkpark.cloud": exit status 1: zone quota exceeded|
           ) == dns
  end

  test "the dns class no longer fires on a string that merely MENTIONS dns" do
    # The deleted `dns` + `failed` leg made the whole class a catch-all. A
    # capacity failure on a site whose SLUG contains `dns` — reachable through
    # the non-admin POST /v1/sites, preserved verbatim into `base.Name` by
    # `Barkpark.provisioning_subdomain/1` — must read as capacity.
    assert FailureCopy.humanize(
             ~s|hcloud server create "acme-dns-site-ac4e1f2a": exit status 1: resource_unavailable|
           ) ==
             "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."
  end

  test "the atomic ip-read-back sub-error is a NETWORK failure, not a domain one" do
    # internal/cli/cloud/provider.go:637 — `hcloud server create %q: ip read-back
    # failed (created server deleted to avoid an orphan): %w`. It carries a
    # dns-bearing name AND the literal word `failed` in ONE line, which is
    # precisely what the deleted leg keyed on. The cause is the wrapped network
    # error, so the person must be told to retry, not to look at their domain.
    raw =
      ~s|hcloud server create "acme-dns-site-ac4e1f2a": ip read-back failed (created server deleted to avoid an orphan): dial tcp: i/o timeout|

    assert FailureCopy.humanize(raw) == "A network step timed out. Retry usually fixes this."
  end

  test "network/timeout jargon → human network copy" do
    network = "A network step timed out. Retry usually fixes this."

    assert FailureCopy.humanize("dial tcp: i/o timeout") == network
  end

  # cch-w28-s5 (D321(3)): this assertion USED to read
  # `humanize("connection refused") == network`, i.e. it pinned the defect as
  # correct behaviour. A refused connection is a peer that answered with an RST —
  # nothing is listening — so "retry usually fixes this" is the one remedy that
  # cannot work. The class is split; the copy names the cause and asks for a
  # CAUSE CHECK, never a retry.
  test "a refused connection is NOT a timeout: its own class, and no retry advice" do
    refused =
      "Nothing is listening on the port we dialled — the service on the box is down or hasn't finished starting. Check the instance's health in the console."

    assert FailureCopy.humanize("connection refused") == refused
    assert FailureCopy.humanize("dial tcp 10.0.0.4:4000: connect: connection refused") == refused
    assert FailureCopy.humanize("ssh: connect to host 1.2.3.4 port 22: ECONNREFUSED") == refused

    # The timeout class keeps its own copy, byte-identical.
    assert FailureCopy.humanize("dial tcp: i/o timeout") ==
             "A network step timed out. Retry usually fixes this."

    # No retry advice, and no phrase an earlier arm would claim on a second pass.
    refute refused =~ ~r/retry/i
    refute String.contains?(refused, "connection refused")
    refute String.contains?(refused, "the instance refused the deploy")
  end

  test "refused-class copy is idempotent under a second pass" do
    for raw <- [
          "connection refused",
          "dial tcp 10.0.0.4:4000: connect: connection refused",
          "ssh: connect to host 1.2.3.4 port 22: ECONNREFUSED"
        ] do
      once = FailureCopy.humanize(raw)
      assert FailureCopy.humanize(once) == once
    end
  end

  test "a dial that retried to its deadline and was REFUSED reads as refused, not timeout" do
    # Both tokens in one capture. The refusal is the actionable half — a closed
    # port stays closed — so the refused arm is checked FIRST.
    raw = "dial tcp 10.0.0.4:4000: i/o timeout after 3 attempts: connection refused"

    assert FailureCopy.humanize(raw) =~ "Nothing is listening on the port we dialled"
  end

  test "provider-class copy is idempotent under a second pass (never re-matches a class)" do
    for raw <- [
          "server type unavailable (SERVER_LIMIT_EXCEEDED)",
          "hcloud: unauthorized (401)",
          ~s|hetzner dns upsert "bp-acme-ac4e1f2a.barkpark.cloud": zone not found|,
          "dial tcp: i/o timeout"
        ] do
      once = FailureCopy.humanize(raw)
      assert FailureCopy.humanize(once) == once
    end
  end

  test "dwb-webhook fail-fast: github-push born-failed reason → blocked-tone human copy naming the workaround" do
    raw =
      "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy"

    human =
      "This push predates GitHub source builds and can't be built yet — push again to build this commit, or deploy it with bp deploy."

    assert FailureCopy.humanize(raw) == human
    # Idempotent under the client failureCopy() second pass (its output does not
    # re-match the "github push builds" token or any other class).
    assert FailureCopy.humanize(human) == human
  end

  test "unrecognized reason passes through unchanged (graceful fallback)" do
    assert FailureCopy.humanize("some brand new worker error") == "some brand new worker error"
    assert FailureCopy.humanize("docker load: no such image") == "docker load: no such image"
  end

  test "nil and non-binary reasons pass through unchanged" do
    assert FailureCopy.humanize(nil) == nil
    assert FailureCopy.humanize(:oops) == :oops
  end

  ## A TYPED REFUSAL IS NEVER HUMANIZED (site-spawner W11).
  ##
  ## humanize/1 matches SUBSTRINGS and replaces the WHOLE string. Nine of the
  ## prebuilt extractor's typed messages interpolate the offending tar entry name
  ## (`Barkpark.Sites.PrebuiltArtifact` — E_ABSOLUTE_PATH, E_PATH_TRAVERSAL,
  ## E_BAD_NAME, E_UNSAFE_PARENT x3, E_WRITE_FAILED x2), so a user-authored path
  ## carrying one common English word used to swallow the whole refusal: an
  ## absolute-path refusal on "/quota/index.html" rendered as "Hetzner ran out of
  ## server capacity", and a "../timeout/" TRAVERSAL — a security event — as "A
  ## network step timed out." The token list cannot be made safe (single common
  ## words vs user-authored paths), so the guard is on the TYPE of the reason.
  ##
  ## Delete the `typed_refusal?(reason) -> reason` clause and every test below
  ## goes red on canned provider copy.

  test "an E_ABSOLUTE_PATH refusal naming /quota/index.html is NOT rewritten as Hetzner capacity" do
    # Byte-for-byte the string `Sites.Deploy.box_refusal/2` composes from the
    # box's nested %{error: %{code, message}} (prebuilt_artifact.ex:626).
    raw =
      ~s|the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry "/quota/index.html" is an absolute path — refused|

    assert FailureCopy.humanize(raw) == raw

    refute FailureCopy.humanize(raw) =~
             "A capacity or quota limit was reached at the hosting provider"
  end

  ## THE SPLIT (task-f156b5e43bfbfe91) — `typed_refusal_fields/1`.
  ##
  ## The guard above stops the fused string being REWRITTEN. It stays fused, and
  ## the next reader takes it apart again by substring: that is what these two
  ## keys end. The table pins the shapes the box actually produces, including
  ## the ones where ONE half is missing — because "the box sent no message" and
  ## "the message is the code" are different sentences and only one is true.

  describe "typed_refusal_fields/1 — the fused refusal, split once" do
    test "an E_* refusal splits into the code and the sentence, em dashes and all" do
      raw =
        ~s|the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry "/quota/index.html" is an absolute path — refused|

      assert FailureCopy.typed_refusal_fields(raw) ==
               {"E_ABSOLUTE_PATH", ~s(entry "/quota/index.html" is an absolute path — refused)}

      # THE FIRST separator only. Nine of the extractor's messages carry their
      # own em dash; splitting on the LAST one would hand back "refused" as the
      # whole message and lose the path the user has to fix.
      assert FailureCopy.typed_refusal_message(raw) =~ "/quota/index.html"
      assert FailureCopy.typed_refusal_code(raw) == "E_ABSOLUTE_PATH"
    end

    test "the shapes with only one half, and the shapes with none" do
      # A bare code, no message — 43% of the 409 corpus predates the nested arm.
      assert FailureCopy.typed_refusal_fields(
               "the instance refused the deploy (HTTP 409): already_running"
             ) == {"already_running", nil}

      # A caption with NO detail at all: nothing to split, and nothing invented.
      assert FailureCopy.typed_refusal_fields("the instance refused the deploy (HTTP 409)") ==
               {nil, nil}

      # Prose with no code. A sentence is never a code, so the code half stays
      # nil rather than swallowing the first clause.
      assert FailureCopy.typed_refusal_fields(
               "the instance refused the deploy (HTTP 500): unknown error"
             ) == {nil, "unknown error"}

      # Not a refusal at all.
      assert FailureCopy.typed_refusal_fields("BUILD failed (exit 12): npm run build") ==
               {nil, nil}

      assert FailureCopy.typed_refusal_fields(nil) == {nil, nil}
      assert FailureCopy.typed_refusal_fields(:atom) == {nil, nil}
    end

    test "the poll caption and the completed-build prefix both split" do
      # `box_refusal/3` writes TWO captions, and `after_completed_build/2` puts
      # a clause carrying its OWN em dash in front of one of them. The split
      # must find the detail AFTER the caption, never the first dash in the line.
      poll =
        "the build completed and staged; the deploy then failed at HEALTH — " <>
          "the instance refused the build poll (HTTP 500): E_SWAP_FAILED — the swap did not complete"

      assert FailureCopy.typed_refusal_fields(poll) ==
               {"E_SWAP_FAILED", "the swap did not complete"}
    end

    test "the [box request_id] stamp is lifted out of the human half" do
      raw =
        "the instance refused the deploy (HTTP 400): E_WRITE_FAILED — could not write entry " <>
          "[box request_id: 01J9X2K4Q]"

      assert FailureCopy.typed_refusal_fields(raw) ==
               {"E_WRITE_FAILED", "could not write entry"}

      # It is a journal join, not something the box SAID — and it still travels
      # whole in `failure_reason`, which is what a reader greps the journal with.
      refute FailureCopy.typed_refusal_message(raw) =~ "request_id"
    end

    test "THE LEAK ARM: the split runs over raw/1, so a colourised credential is redacted" do
      # A refusal message is a REMOTE CAPTURE. A structured twin derived from
      # the unscrubbed column would ship the credential its own neighbour
      # `failure_reason_raw` redacts — the "eighth channel added later" shape.
      # Colourised, because that is the order-dependent case: `scrub |> strip`
      # leaks 2000/2000, `strip |> scrub` leaks 0.
      raw =
        "the instance refused the deploy (HTTP 400): \e[31mclient_secret=hunter2istheworstpassword\e[0m"

      {code, message} = FailureCopy.typed_refusal_fields(raw)

      assert code == nil
      refute message =~ "hunter2istheworstpassword"
      assert message =~ "[redacted]"
    end
  end

  test "a PATH TRAVERSAL through ../timeout/ is NOT rewritten as a network timeout" do
    raw =
      ~s|the instance refused the deploy (HTTP 400): E_PATH_TRAVERSAL — entry "../timeout/index.html" escapes the artifact root|

    assert FailureCopy.humanize(raw) == raw
    refute FailureCopy.humanize(raw) =~ "A network step timed out"
  end

  test "the colliding static-site slugs are pinned as a set, not one example" do
    # Ordinary static-site error pages and doc paths — `timeout.html` and
    # `unauthorized.html` are what a framework's error pages are CALLED, and
    # /quota, /dns/failed.html are ordinary content slugs.
    slugs = [
      {"E_ABSOLUTE_PATH", ~s(entry "/quota/index.html" is an absolute path — refused)},
      {"E_ABSOLUTE_PATH", ~s(entry "/timeout.html" is an absolute path — refused)},
      {"E_ABSOLUTE_PATH", ~s(entry "/unauthorized.html" is an absolute path — refused)},
      {"E_PATH_TRAVERSAL", ~s(entry "../dns/failed.html" escapes the artifact root)},
      {"E_BAD_NAME", ~s(entry "docs/quota/index.html" names the artifact root itself as a file)},
      {"E_UNSAFE_PARENT",
       ~s(the archive names "/srv/x/errors/unauthorized/index.html" more than once)}
    ]

    canned = [
      "A capacity or quota limit was reached at the hosting provider",
      "A network step timed out",
      "A credential was rejected.",
      "Securing the domain failed"
    ]

    for {code, message} <- slugs do
      raw = "the instance refused the deploy (HTTP 400): #{code} — #{message}"
      out = FailureCopy.humanize(raw)

      assert out == raw, "#{code} was rewritten: #{out}"
      assert out =~ code
      assert out =~ message

      for copy <- canned do
        refute out =~ copy
      end
    end
  end

  test "a bare E_* code with no box-refusal prefix is still recognized as typed" do
    raw = ~s(E_UNKNOWN_TYPE — unsupported tar entry type "x")
    assert FailureCopy.humanize(raw) == raw
  end

  test "the box-refusal prefix alone is enough — the box already said no in its own words" do
    raw = "the instance refused the deploy (HTTP 502)"
    assert FailureCopy.humanize(raw) == raw
  end

  test "typed pass-through is idempotent (a second client-side pass changes nothing)" do
    raw =
      ~s|the instance refused the deploy (HTTP 400): E_PATH_TRAVERSAL — entry "../timeout/" escapes the artifact root|

    assert raw |> FailureCopy.humanize() |> FailureCopy.humanize() == raw
  end

  test "the guard is NOT a blanket bypass: untyped provider jargon is still humanized" do
    # The two clauses the colliding slugs above stole. A reason with no typed code
    # and no box-refusal prefix keeps the pre-W11 behaviour exactly.
    assert FailureCopy.humanize("account quota exceeded for servers") ==
             "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."

    assert FailureCopy.humanize("dial tcp: i/o timeout") ==
             "A network step timed out. Retry usually fixes this."

    # An ALL-CAPS provider code that merely ENDS in `E_…` must not read as typed:
    # `_` is a word character, so `\bE_` has no boundary to match inside it.
    refute FailureCopy.typed_refusal?("server type unavailable (SERVER_LIMIT_EXCEEDED)")
    refute FailureCopy.typed_refusal?("RESOURCE_UNAVAILABLE")
    refute FailureCopy.typed_refusal?(nil)
    assert FailureCopy.typed_refusal?("E_NO_INDEX — the archive has no index.html")
  end

  # ── Azure provider classes (provider-neutral hosting) — each names the exact
  # Azure Portal fix, and none collides with the Hetzner classes above.

  test "azure quota-exceeded-per-family → the vCPU-quota copy naming the portal fix" do
    quota =
      "Your Azure subscription's vCPU quota for this VM family is exhausted. In the Azure Portal → Subscriptions → your subscription → Usage + quotas, filter to the family and choose Request increase, then retry."

    assert FailureCopy.humanize(
             "QuotaExceeded: Operation results in exceeding approved standardDPSv5Family Cores quota"
           ) == quota

    assert FailureCopy.humanize("Compute quota (vCPU) exceeded") == quota
    # Idempotent — the copy re-maps to itself (it contains quota + vcpu + family).
    assert FailureCopy.humanize(quota) == quota
  end

  test "azure region-capacity → the region-capacity copy" do
    capacity =
      "This Azure region has no capacity for this VM size right now. In the Azure Portal → Virtual machines, pick another region or size — or retry shortly, since capacity is transient per region and size."

    assert FailureCopy.humanize("SkuNotAvailable: the requested size is not available") ==
             capacity

    assert FailureCopy.humanize("AllocationFailed: unable to allocate") == capacity
    assert FailureCopy.humanize("ZonalAllocationFailed in zone 2") == capacity
    assert FailureCopy.humanize(capacity) == capacity
  end

  test "azure missing-RBAC-role → the role-assignment copy, before the generic auth class" do
    rbac =
      "Your Azure service principal is missing a role. In the Azure Portal → Subscriptions → your subscription → Access control (IAM) → Add role assignment, grant it the Contributor role, then reconnect."

    assert FailureCopy.humanize(
             "AuthorizationFailed: The client does not have authorization to perform action"
           ) == rbac

    assert FailureCopy.humanize("does not have permission to write") == rbac
    assert FailureCopy.humanize(rbac) == rbac
  end

  test "the generic capacity arm does not swallow the azure family-quota arm" do
    # THE DISCRIMINATION SURVIVES THE NARROWING (wave 29). Making the generic
    # copy provider- and resource-neutral must not start answering the strings
    # the family arm answers PRECISELY: a quota capture that carries `family` or
    # `vcpu` still gets the exact Portal path, not the neutral sentence.
    family =
      "Your Azure subscription's vCPU quota for this VM family is exhausted. In the Azure Portal → Subscriptions → your subscription → Usage + quotas, filter to the family and choose Request increase, then retry."

    for raw <- [
          "QuotaExceeded: no vCPUs left",
          "quota reached for the standardDSv3 family",
          "operation failed: quota exceeded (vcpu)"
        ] do
      assert FailureCopy.humanize(raw) == family, "swallowed by the generic arm: #{raw}"
      refute FailureCopy.humanize(raw) =~ "A capacity or quota limit was reached"
    end
  end

  test "the azure classes do not steal the generic capacity string" do
    # Hetzner's spaced 'account quota exceeded' still reads as capacity, NOT the
    # azure family-quota copy (no 'quotaexceeded'/'family'/'vcpu' token).
    assert FailureCopy.humanize("account quota exceeded for servers") ==
             "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."
  end

  ## THE FALLBACK-LADDER AGGREGATE IS CLASSIFIED PER SUB-ERROR (wave 25 S1).
  ##
  ## `CreateWithFallback` folds every candidate's failure into ONE string, so a
  ## substring scan of the whole concatenation fires on any token ANY candidate
  ## mentioned, on the header's own literal `failed`, and on the user's own slug.

  @capacity "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."
  @dns_copy "Securing the domain failed on the provider side."
  @network "A network step timed out. Retry usually fixes this."
  @auth "A credential was rejected. This capture doesn't say whose credential it was — the raw error line names it."

  # internal/cli/cloud/provider.go:543-552 — HetznerCandidates' resilience
  # ladder: base plus four fallbacks, deduped.
  @ladder [
    {"cx22", "fsn1"},
    {"cx23", "fsn1"},
    {"cx23", "hel1"},
    {"cx33", "nbg1"},
    {"cpx22", "fsn1"}
  ]

  # DERIVED, never pasted. `CreateWithFallback`
  # (internal/cli/cloud/provider.go:569-578, READ-ONLY) composes exactly:
  #
  #   fmt.Errorf("create %q failed on all %d candidate type/locations:%s",
  #              base.Name, len(candidates), sb.String())
  #   fmt.Fprintf(&sb, "\n  - %s/%s: %s", spec.ServerType, spec.Region, err)
  #
  # so the header ends AT the colon with NO trailing space, and every entry is
  # newline-two-space-dash prefixed. Composing from those two shapes is what
  # makes these fixtures red when the producer's format changes.
  defp aggregate(name, sub_errors) do
    entries =
      sub_errors
      |> Enum.zip(@ladder)
      |> Enum.map_join(fn {err, {type, region}} -> "\n  - #{type}/#{region}: #{err}" end)

    ~s|create "#{name}" failed on all #{length(sub_errors)} candidate type/locations:| <>
      entries
  end

  # internal/cli/cloud/provider.go:614 — `hcloud server create %q: %w: %s`,
  # with hcloud's captured stderr as the tail.
  defp create_failed(name, stderr) do
    ~s|hcloud server create "#{name}": exit status 1: #{stderr}|
  end

  describe "humanize/1 — the fallback-ladder aggregate" do
    # TRIGGER A — every sub-error is capacity, on a slug CONTAINING `dns`. The
    # slug reaches `base.Name` verbatim (Barkpark.provisioning_subdomain/1) and
    # is reachable through the non-admin POST /v1/sites, so before the split this
    # person was told "Securing the domain failed" on every single attempt.
    test "A: a wholly-capacity aggregate on a dns-bearing slug reads as CAPACITY" do
      raw =
        aggregate(
          "acme-dns-site-ac4e1f2a",
          List.duplicate(create_failed("acme-dns-site-ac4e1f2a", "resource_unavailable"), 5)
        )

      assert FailureCopy.aggregate?(raw)
      assert FailureCopy.humanize(raw) == @capacity
      refute FailureCopy.humanize(raw) == @dns_copy
    end

    # CONTROL C — byte-identical to A except the slug. If the fix were a blanket
    # disabling of the DNS class, A and C would both pass while the real emitters
    # above went red; they don't, so this pair isolates the cause to the slug.
    test "C control: the same aggregate on a plain slug also reads as CAPACITY" do
      plain =
        aggregate(
          "bp-stopwatch-ac4e1f2a",
          List.duplicate(create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"), 5)
        )

      cruel =
        aggregate(
          "acme-dns-site-ac4e1f2a",
          List.duplicate(create_failed("acme-dns-site-ac4e1f2a", "resource_unavailable"), 5)
        )

      # The ONLY difference between the two fixtures is the slug.
      assert String.replace(cruel, "acme-dns-site", "bp-stopwatch") == plain
      assert FailureCopy.humanize(plain) == @capacity
      assert FailureCopy.humanize(cruel) == FailureCopy.humanize(plain)
    end

    # TRIGGER B — one dns sub-error of five no longer outvotes the other four.
    test "B: 1 dns + 4 capacity sub-errors reads as CAPACITY, not domain" do
      raw =
        aggregate("bp-stopwatch-ac4e1f2a", [
          ~s|hetzner dns upsert "bp-stopwatch-ac4e1f2a.barkpark.cloud": zone not found|,
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"),
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"),
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"),
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable")
        ])

      assert FailureCopy.humanize(raw) == @capacity
    end

    # The mirror of B: a genuine plurality of dns sub-errors still wins, so the
    # split is not a way of never saying "domain" again.
    test "a dns-dominated aggregate still reads as DOMAIN" do
      raw =
        aggregate("bp-stopwatch-ac4e1f2a", [
          ~s|hetzner dns upsert "bp-stopwatch-ac4e1f2a.barkpark.cloud": zone not found|,
          ~s|hetzner dns delete "bp-stopwatch-ac4e1f2a.barkpark.cloud": status 409|,
          ~s|hcloud zone rrset set-records "bp-stopwatch-ac4e1f2a.barkpark.cloud": exit status 1: rrset invalid|,
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable")
        ])

      assert FailureCopy.humanize(raw) == @dns_copy
    end

    # The ip read-back INSIDE an aggregate: dns-bearing name AND `failed` in one
    # line, five times over, and still a network fault.
    test "an all-ip-read-back aggregate reads as NETWORK" do
      raw =
        aggregate(
          "acme-dns-site-ac4e1f2a",
          for _ <- 1..5 do
            ~s|hcloud server create "acme-dns-site-ac4e1f2a": ip read-back failed (created server deleted to avoid an orphan): dial tcp: i/o timeout|
          end
        )

      assert FailureCopy.humanize(raw) == @network
    end

    # THE TIE RULE (charter D295): a tie falls through to the RAW pass-through.
    # Note the atomic path would have said CAPACITY here — capacity is checked
    # before auth — so this also proves the aggregate arm is the one running.
    test "a TIE falls through to the raw string, verbatim" do
      raw =
        aggregate("bp-stopwatch-ac4e1f2a", [
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"),
          create_failed("bp-stopwatch-ac4e1f2a", "unauthorized (401)"),
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"),
          create_failed("bp-stopwatch-ac4e1f2a", "unauthorized (401)")
        ])

      assert FailureCopy.humanize(raw) == raw
      refute FailureCopy.humanize(raw) == @capacity
      refute FailureCopy.humanize(raw) == @auth
    end

    test "an aggregate whose sub-errors all classify to NOTHING passes through raw" do
      raw =
        aggregate("bp-stopwatch-ac4e1f2a", [
          create_failed("bp-stopwatch-ac4e1f2a", "ssh key not found"),
          create_failed("bp-stopwatch-ac4e1f2a", "ssh key not found")
        ])

      assert FailureCopy.humanize(raw) == raw
    end

    # BOTH markers are required. The discriminator is a TIE fixture: the
    # aggregate arm returns it raw, while the atomic arm classifies the whole
    # concatenation as capacity — so a string that takes the atomic arm is
    # visibly different, not merely "also correct".
    test "aggregate?/1 needs BOTH the header and the newline-two-space-dash separator" do
      tie =
        aggregate("bp-stopwatch-ac4e1f2a", [
          create_failed("bp-stopwatch-ac4e1f2a", "resource_unavailable"),
          create_failed("bp-stopwatch-ac4e1f2a", "unauthorized (401)")
        ])

      assert FailureCopy.aggregate?(tie)
      assert FailureCopy.humanize(tie) == tie

      # Header, but the entries are comma-joined — NOT the producer's separator.
      header_only = String.replace(tie, "\n  - ", ", ")
      refute FailureCopy.aggregate?(header_only)
      assert FailureCopy.humanize(header_only) == @capacity

      # The separator, but no header phrase: ordinary list formatting in an
      # operator note.
      separator_only =
        String.replace(
          tie,
          ~s|create "bp-stopwatch-ac4e1f2a" failed on all 2 candidate type/locations:|,
          "provisioning notes:"
        )

      refute FailureCopy.aggregate?(separator_only)
      assert FailureCopy.humanize(separator_only) == @capacity

      refute FailureCopy.aggregate?(nil)
      refute FailureCopy.aggregate?("exceeded max provision attempts (3)")
    end

    # The aggregate is WRAPPED by its callers before it is stored
    # (internal/cli/cloud/restore_driver.go:137 `resurrect create %q: %w`,
    # warmpool_assign.go:30 `create warm server %q: %w`), so the header must not
    # be anchored at the start of the string.
    test "a WRAPPED aggregate still takes the aggregate arm" do
      raw =
        aggregate(
          "acme-dns-site-ac4e1f2a",
          List.duplicate(create_failed("acme-dns-site-ac4e1f2a", "resource_unavailable"), 5)
        )

      wrapped = ~s|resurrect create "acme-dns-site-ac4e1f2a": | <> raw

      assert FailureCopy.aggregate?(wrapped)
      assert FailureCopy.humanize(wrapped) == @capacity
    end

    # A typed refusal is still checked FIRST: it can never be split.
    test "a typed refusal carrying both markers is still passed through verbatim" do
      raw =
        ~s|the instance refused the deploy (HTTP 400): E_BAD_NAME — | <>
          aggregate("x", [create_failed("x", "resource_unavailable")])

      assert FailureCopy.humanize(raw) == raw
    end

    test "aggregate output is idempotent under the client's second pass" do
      raw =
        aggregate(
          "acme-dns-site-ac4e1f2a",
          List.duplicate(create_failed("acme-dns-site-ac4e1f2a", "resource_unavailable"), 5)
        )

      once = FailureCopy.humanize(raw)
      assert FailureCopy.humanize(once) == once
    end
  end

  # ── site-spawner D28: the STATIC twin of "no build source". Its RAW string is
  # asserted in registry_deployment_reaper_test.exs; its HUMANIZED output was
  # asserted NOWHERE until wave 25 S1.

  test "no-content-binding jargon → copy naming the --dataset cure, not 'connect a repo'" do
    human = FailureCopy.humanize("site has no content binding (no dataset attached)")

    assert human ==
             "This site isn't bound to any content yet. Create it with --dataset <workspace>/<project>/<dataset>."

    # It must NOT get the repo-flavoured "no build source" copy: a content-bound
    # site builds from a Barkpark dataset, so "connect a repo" names neither the
    # cause nor the cure.
    refute human =~ "Connect a repo"
    # Idempotent under the client's second pass.
    assert FailureCopy.humanize(human) == human
  end

  # ── connect_remediation/1 — verify-before-save copy naming the exact console.

  test "connect_remediation names the exact Hetzner + Azure console fix" do
    assert FailureCopy.connect_remediation("hetzner") =~ "Hetzner Cloud Console"
    assert FailureCopy.connect_remediation("hetzner") =~ "API tokens"
    assert FailureCopy.connect_remediation("azure") =~ "App registrations"
    assert FailureCopy.connect_remediation("azure") =~ "Certificates & secrets"
    # Unknown kind falls back to a provider-agnostic, actionable line.
    assert FailureCopy.connect_remediation("gcp") =~ "verify"
  end

  test "connect_remediation names the exact Cloudflare console fix (CONTENT, not parity)" do
    # router_providers_catalog_test.exs asserts the ROUTE payload equals
    # `FailureCopy.connect_remediation("cloudflare")` — real route/function parity,
    # but it cannot lose on CONTENT: blank the copy and it stays green. This row
    # is the content half, matching the hetzner/azure rows above.
    cloudflare = FailureCopy.connect_remediation("cloudflare")

    assert cloudflare =~ "Cloudflare dashboard"
    assert cloudflare =~ "API Tokens"
    assert cloudflare =~ "DNS"
    # And it must not be the provider-agnostic fallback.
    refute cloudflare == FailureCopy.connect_remediation("gcp")
  end

  # ── provider_not_connected_remediation/1 — the launch-time "connect first" copy.

  test "provider_not_connected_remediation points azure launches at Providers → connect" do
    azure = FailureCopy.provider_not_connected_remediation("azure")
    assert azure =~ "Providers"
    assert azure =~ "Azure"
    # Unknown kind falls back to a provider-agnostic connect-first line.
    assert FailureCopy.provider_not_connected_remediation("gcp") =~ "Providers"
  end

  # ── capability_gap_reason/2 — the honest-degradation copy for a FALSE
  # capability, server-owned so the SPA + CLI read one reason (charter D8/D16).

  test "azure adopt is the ONE named gap; archive + resurrect are live capabilities (S14)" do
    assert FailureCopy.capability_gap_reason("azure", "adopt") =~ "clone-swap"

    # archive (S14b, portable bp-bundle-v1) and resurrect (S14d, bundle restore
    # target) are LIVE capabilities now, so their bespoke gap clauses are gone —
    # both fall through to the generic terminal clause, kept only as defensive
    # coverage, never advertised as a gap.
    refute FailureCopy.capability_gap_reason("azure", "archive") =~ "Azure has no archive"
    refute FailureCopy.capability_gap_reason("azure", "resurrect") =~ "Azure has no archives"
  end

  test "hetzner pause gap names deletion — the only act that stops the charge (cch-w55-s2)" do
    reason = FailureCopy.capability_gap_reason("hetzner", "pause")
    assert reason =~ "Hetzner"
    assert reason =~ "bill"
    assert reason =~ "Deleting"

    # WHY THE OLD ASSERTION WAS WRONG. This arm used to read `assert reason =~
    # "Archive"`, pinning the copy "Archive it to stop paying and resurrect it
    # later." It passed for the whole time the sentence was false: no archive
    # path in this tree touches a server's power or existence (the portable
    # `runNeutralArchive` SSH-collects a bundle and returns; the `--fast` path's
    # `--stop` is "never a hard stop"), and Hetzner bills a server "for as long
    # as it exists, regardless of whether it is turned on or not" AND bills
    # snapshots "per gigabyte per month"
    # (https://docs.hetzner.com/cloud/billing/faq/). The prescribed remedy
    # therefore INCREASED the operator's bill. A substring assertion can only
    # pin the words we chose, never their truth — so the retraction is pinned
    # negatively too: archiving must never again be sold as a way to stop
    # paying.
    refute reason =~ "Archive"
    refute reason =~ "stop paying"
  end

  test "catalog gap is generic across kinds and names the fixed-defaults fallback" do
    for kind <- ["hetzner", "azure", "gcp"] do
      reason = FailureCopy.capability_gap_reason(kind, "catalog")
      assert reason =~ "catalog"
      assert reason =~ "fixed defaults"
    end
  end

  test "every capability key resolves to non-empty copy — no false capability is reason-less" do
    # The union of capability keys any provider row could carry today, plus a
    # made-up one to prove the terminal default clause covers a key added later
    # (S9's facet split) with zero FailureCopy change.
    for kind <- ["hetzner", "azure", "fake", "brand-new-provider"],
        capability <-
          ~w(core catalog archive resurrect decommission adopt audit pause labels some_future_facet) do
      reason = FailureCopy.capability_gap_reason(kind, capability)

      assert is_binary(reason) and reason != "",
             "no gap reason for #{kind}/#{capability}"
    end
  end

  test "the terminal default clause interpolates an unknown capability name" do
    assert FailureCopy.capability_gap_reason("gcp", "snapshots") =~ "snapshots"
  end

  ## Secret scrubbing at the display boundary (wave 13 S2)

  describe "scrub/1 — the pattern table" do
    # Two fixtures are ASSEMBLED rather than written out. They are synthetic by
    # construction (nothing here ever authenticated anything), but GitHub push
    # protection blocks a literal `AKIA` + 16 uppercase alphanumerics and a bare
    # 40-char high-entropy run on sight — which is the scanner doing exactly its
    # job, and a job worth keeping enabled. Splitting the source literal gives the
    # scanner nothing to match while the RUNTIME bytes under test are unchanged,
    # so the AWS-key clause and the bare-token clause are still driven end to end.
    # Do NOT re-inline these: the push is refused, and the fix is not an allowlist.
    @aws_key "AKIA" <> "Q7ZLMNPR" <> "4TV6WY2X"
    @bare_token "Kj8Xm2QpL9vR4tZ7" <> "wN1cB6yH3sD5" <> "fG0aQ2eR7uI9"

    # BARKPARK'S OWN credential shapes, assembled for the same reason as above.
    # `bppat_` is the self-service PAT (`Barkpark.Auth.create_personal_access_token/3`)
    # and `bpcs_` the scoped chat/MCP session token — both are
    # `<prefix> <> Base.url_encode64(32 random bytes, padding: false)`, so the
    # body is 43 chars of `[A-Za-z0-9\-_]`. The `-`/`_` inside is exactly why the
    # bare-token clause (contiguous alnum only) could not see them: measured over
    # 2,000 freshly minted tokens against the pre-fix module, four of six carrier
    # shapes leaked 93.6% and the rest redacted only by accident of the alphabet.
    # A `-` and a `_` are kept IN the bodies here on purpose — a body without one
    # is the ~6% lucky case and would pass even unfixed.
    @bppat "bppat_" <> "9aB3xQ7z-LmNpR4tV" <> "6wY2_Kj8Xm2QpL9vR4tZ7wN1cB"
    @bpcs "bpcs_" <> "Zx7Qm2Lp-9Vr4Tz8W" <> "n1Cb6Yh3_sD5fG0aQ2eR7uI9K"

    # A Bearer credential that NO other clause can reach: no vendor prefix, no
    # `key=`/`token=` separator, and 20 chars — under the bare-token clause's 32.
    # Every pre-existing Bearer positive used `sk-live-…`, which the
    # provider-prefix clause redacts on its own, so deleting the ENTIRE Bearer
    # clause left the table fully green while `Bearer <token>` went 0.0% -> 94.2%
    # leaked. This row is the only thing that reds on that mutation.
    @unprefixed_bearer "nJq2LmT4vB" <> "7nR1zC8kW5"

    # THE MINTED PER-INSTANCE CREDENTIALS. `bp_admin_…` / `bp_read_…` are what
    # `setup.GenerateAdminToken` actually mints and what the provisioner installs
    # on every box — `internal/provisioner/console.go`'s `adminTokenRe` exists for
    # exactly this shape, and `internal/builder/console.go`'s `builderTokenRe`
    # generalises it to `bp_[a-z]+_`. This module's provider-prefix clause knew
    # `bppat_`/`bpcs_` but NOT the `bp_<kind>_` family, so the one credential the
    # control plane mints for every provisioned site was the one it could not see.
    #
    # A `-` and a `_` are kept in each body on purpose: without one the body is a
    # contiguous 32+ mixed-case alnum run and the BARE-TOKEN clause redacts it by
    # accident, which would make these rows pass even unfixed.
    @bp_admin "bp_admin_" <> "9aB3xQ7z-LmNpR4tV" <> "6wY2_Kj8Xm2QpL9vR4tZ7wN1cB"
    @bp_read "bp_read_" <> "Zx7Qm2Lp-9Vr4Tz8W" <> "n1Cb6Yh3_sD5fG0aQ2eR7uI9K"

    # A DATABASE_URL's userinfo. The Go runner has carried `ectoUserinfoRe` since
    # the scrub was written (`internal/cli/cloud/warmpool.go`), but THIS boundary
    # never grew the clause: `DATABASE_URL` is not one of the key clause's key
    # words, and the password sits behind a `//` that no other clause reaches — so
    # the DB password shipped to the screen in cleartext.
    @db_password "Qp9vR4tZ-7wN1cB6yH3sD5fG0"

    # POSITIVES: every shape a remote capture can carry a live credential in.
    # Each row is {label, input, must_not_survive}.
    @positives [
      {"Authorization: Bearer",
       "ssh: remote said Authorization: Bearer sk-live-9aB3xQ7zLmNpR4tV6wY2",
       "sk-live-9aB3xQ7zLmNpR4tV6wY2"},
      {"client_secret=", "az login failed: client_secret=Qp9vR4tZ7wN1cB6yH3sD5fG0",
       "Qp9vR4tZ7wN1cB6yH3sD5fG0"},
      {"token= (env fold)", "provisioner env: HCLOUD_TOKEN=Kj8Xm2QpL9vR4tZ7wN1cB6yH3sD5fG0aQ2eR",
       "Kj8Xm2QpL9vR4tZ7wN1cB6yH3sD5fG0aQ2eR"},
      {"api_key: with quotes", ~s(config wrote api_key: "Zx7Qm2Lp9Vr4Tz8Wn1Cb6Yh3"),
       "Zx7Qm2Lp9Vr4Tz8Wn1Cb6Yh3"},
      {"password:", "sftp: password: hunter2-Correct-Horse", "hunter2-Correct-Horse"},
      {"github pat prefix", "git fetch failed for ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5",
       "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5"},
      {"slack webhook token", "notify failed: xoxb-9aB3xQ7zLmNpR4tV", "xoxb-9aB3xQ7zLmNpR4tV"},
      {"aws access key id", "s3 sync refused key " <> @aws_key, @aws_key},
      {"bare mixed-case 40-char provider token", "provider rejected " <> @bare_token,
       @bare_token},

      # OUR OWN credential, in the four shapes that leaked 93.6% before the
      # provider-prefix clause learned `bppat_`/`bpcs_`. The clause matches the
      # TOKEN, not the syntax around it, so all four close at once — which is the
      # whole argument for fixing it there rather than at each carrier.
      {"barkpark PAT in an env fold", "provisioner env: BARKPARK_TOKEN=" <> @bppat, @bppat},
      {"barkpark PAT after export (no `\\b` before TOKEN)", "+ export BARKPARK_TOKEN=" <> @bppat,
       @bppat},
      {"barkpark PAT bare in prose (no key, no separator)", "using token " <> @bppat <> " ok",
       @bppat},
      {"barkpark PAT behind a colour code", "\e[31mtoken=" <> @bppat <> "\e[0m", @bppat},
      {"barkpark PAT as a Bearer credential", "ssh: remote said Authorization: Bearer " <> @bppat,
       @bppat},
      {"barkpark chat/MCP session token (bpcs_)", "spawn failed: BARKPARK_API_TOKEN=" <> @bpcs,
       @bpcs},
      {"barkpark chat/MCP session token bare in prose",
       "child inherited " <> @bpcs <> " and exited 1", @bpcs},

      # The Bearer clause's ONLY independent pin — see @unprefixed_bearer.
      {"Bearer with a token no other clause can reach",
       "ssh: remote said Authorization: Bearer " <> @unprefixed_bearer, @unprefixed_bearer},

      # Fix B's own reach: `(?<![A-Za-z0-9])` also opens the key clause to every
      # other SCREAMING_SNAKE env var, not just ours.
      {"generic SCREAMING_SNAKE env secret", "env: MY_SECRET=Qp9vR4tZ7wN1cB6yH3sD5fG0",
       "Qp9vR4tZ7wN1cB6yH3sD5fG0"},
      {"generic SCREAMING_SNAKE env token", "env: DEPLOY_TOKEN=Zx7Qm2Lp9Vr4Tz8Wn1Cb6Yh3",
       "Zx7Qm2Lp9Vr4Tz8Wn1Cb6Yh3"},

      # THE MINTED BOX CREDENTIAL, bare in prose — the one carrier shape no other
      # clause can reach. In an env fold (`ADMIN_TOKEN=bp_admin_…`) the key clause
      # already covers it and as a `Bearer` the bearer clause does, so BARE is the
      # only row that isolates the provider-prefix clause and reds on its absence.
      {"minted admin token bare in prose", "installed " <> @bp_admin <> " on the box", @bp_admin},
      {"minted read token bare in prose", "agent inherited " <> @bp_read <> " and exited 1",
       @bp_read},

      # A DATABASE_URL fold. The password lives in the URL's userinfo, which the
      # key clause cannot see (`DATABASE_URL` is not one of its key words, and the
      # value it would take is the whole URL only if it matched at all).
      {"ecto URL userinfo (DATABASE_URL fold)",
       "migrate failed: DATABASE_URL=ecto://bp_user:" <>
         @db_password <> "@db.internal:5432/barkpark", @db_password},
      {"postgres URL userinfo bare in prose",
       "repo could not connect to postgres://admin:" <> @db_password <> "@10.0.0.4/bp",
       @db_password}
    ]

    # NEGATIVES: shapes a person NEEDS to read. A redacted git SHA costs them the
    # commit they deployed and is indistinguishable from a redacted token, so the
    # naive `\b[A-Za-z0-9]{40,}\b` shape is rejected here by construction.
    @negatives [
      {"40-char git SHA", "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed"},
      {"uuid job id", "provision job 550e8400-e29b-41d4-a716-446655440000 timed out"},
      {"hostname", "dial tcp: bp-mysite.barkpark.cloud:443 connection refused"},
      {"semver", "agent v1.24.3-rc.1 is older than the required v1.25.0"},
      {"sha256 image digest",
       "image sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 not found"},
      {"base64 digest", "integrity sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="},
      {"provider jargon (DESIGN.md §5 keeps the fold verbatim)",
       "SERVER_LIMIT_EXCEEDED: no server of type cax11 free in fsn1"},
      {"reaper jargon", "exceeded max provision attempts (3)"},
      # STATUS PROSE in a value position. These were live false positives before
      # the `@prose_value` guard: an unguarded `bearer\s+\S+` rendered the first
      # one "no bearer [redacted] found in the request" — a redaction where no
      # secret ever was, which is the same class of lie this wave is paying off.
      {"prose after Bearer", "no bearer token found in the request"},
      {"prose after Bearer (capitalised)", "missing Bearer credentials"},
      {"prose in a token value", "token: expired"},
      {"prose in an api_key value", "no api_key: set in the config file"},
      {"prose in a password value", "sftp refused: password: missing"},

      # The new `bppat_`/`bpcs_` arm's false-positive surface, pinned. Each of
      # these is copy a person needs verbatim to act on the failure.
      {"the bpcs mint-refused sentinel (hyphen, not a token)",
       "chat spawn refused: bpcs-mint-refused"},
      {"a provisioned site hostname (`bp-` is NOT a credential prefix)",
       "dial tcp: bp-acme-ac4e1f2a.barkpark.cloud:443 connection refused"},
      {"the prefix NAMED in prose, with no body after it",
       "expected a token with the bppat_ prefix"},
      {"a word merely ENDING in token (Fix B's lookbehind excludes alnum)",
       "xtoken=cax11 is not a recognised flag"},

      # Fix B widened the key clause's left edge to `_`, which put every
      # `*_password`/`*_token` identifier in a stack trace or source echo inside
      # its reach. A COMPARISON is not an assignment: `=` is not in the value
      # clause's stop set, so without the `(?![=:])` guard the second `=` of
      # `==` became "the value" and a captured source line rendered
      # "hashed_password =[redacted] before" — copy loss where no secret was.
      {"an Elixir comparison echoed from a stack trace, not an assignment",
       "match failed: hashed_password == before"},
      {"a guard clause echoed from the build log", "refused because deploy_token == nil"},

      # THE PLACEHOLDER. `internal/provisioner/support.go` deliberately narrates
      # the provider-key hand-off with the VAR NAME and an angle-bracket
      # placeholder, because the key is the one secret Barkpark never copies — the
      # developer pastes it themselves. That line is an INSTRUCTION, and the key
      # clause was redacting `<your-key>` into `[redacted]`, destroying the only
      # copy telling the person what to type. A real credential never starts with
      # `<`, so excluding that one byte costs the redaction nothing.
      {"the provider-key hand-off instruction keeps its placeholder",
       ~s(hand the box its key: printf 'ANTHROPIC_API_KEY=<your-key>\\n' >> /etc/barkpark/fleet-listener.env)},
      {"a generic angle-bracket placeholder in a key position", "set api_key=<paste-it-here>"}
    ]

    for {label, input, secret} <- @positives do
      test "positive: #{label} is redacted" do
        out = FailureCopy.scrub(unquote(input))

        refute out =~ unquote(secret),
               "the secret survived the scrub: #{out}"

        assert out =~ "[redacted]"
      end
    end

    for {label, input} <- @negatives do
      test "negative: #{label} survives verbatim" do
        assert FailureCopy.scrub(unquote(input)) == unquote(input)
      end
    end

    test "the naive \\b[A-Za-z0-9]{40,}\\b shape is REJECTED — it eats a git SHA" do
      sha_line = "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed"
      naive = ~r/\b[A-Za-z0-9]{40,}\b/

      # What the rejected pattern would have shipped — a person loses the commit.
      assert Regex.replace(naive, sha_line, "[redacted]") == "build of [redacted] failed"

      # What we actually ship.
      assert FailureCopy.scrub(sha_line) == sha_line
    end

    test "scrub/1 is idempotent and no-ops on non-binaries" do
      once = FailureCopy.scrub("client_secret=Qp9vR4tZ7wN1cB6yH3sD5fG0")
      assert FailureCopy.scrub(once) == once
      assert FailureCopy.scrub(nil) == nil
      assert FailureCopy.scrub(%{a: 1}) == %{a: 1}
    end

    test "the key and its shape survive — the redaction names what leaked" do
      assert FailureCopy.scrub("az login failed: client_secret=Qp9vR4tZ7wN1cB6yH3sD5fG0") ==
               "az login failed: client_secret=[redacted]"

      assert FailureCopy.scrub("Authorization: Bearer sk-live-9aB3xQ7zLmNpR4tV6wY2") ==
               "Authorization: Bearer [redacted]"
    end

    # THE ORDER, for a path that does NOT classify. `classify/1` still runs FIRST
    # wherever it runs at all (its prefixes are producer-anchored and an escape
    # run can sit inside them), but the STRIP now precedes the SCRUB on every
    # path — `raw/1` and `humanize/1` alike. Under the old tail the key clause redacts
    # up to the next delimiter, and a colour code parks a non-delimiter byte
    # (`m`) immediately before the key, so the clause never fires. Measured over
    # 2,000 random values: `scrub |> strip_ansi` 2000/2000 leaked,
    # `strip_ansi |> scrub` 0/2000.
    #
    # `bppat_`/`bpcs_` are order-INDEPENDENT (the provider-prefix clause matches
    # the token itself), which is precisely why this test uses a NON-prefixed
    # `api_key=` secret — otherwise the wrong order would look safe.
    test "raw-log order: strip_ansi BEFORE scrub — the shipped order leaks a colourised api_key" do
      secret = "Qp9vR4tZ7wN1cB6yH3sD5fG0"
      line = "\e[31mapi_key=#{secret}\e[0m"

      # dr-w22-s1: this assertion USED to be `assert … scrub() |> strip_ansi() =~
      # secret` — a guard that PINNED the leak in place, and would have gone red
      # on the fix. It is a refutation now, and the shipped entry point is
      # `raw/1`: no display boundary composes these two by hand any more.
      refute FailureCopy.raw(line) =~ secret
      assert FailureCopy.raw(line) == "api_key=[redacted]"

      # The bare pair still documents WHICH order is the safe one, and the wrong
      # order is now recorded as the defect it is rather than asserted as truth.
      refute line |> FailureCopy.strip_ansi() |> FailureCopy.scrub() =~ secret
      assert line |> FailureCopy.strip_ansi() |> FailureCopy.scrub() == "api_key=[redacted]"
    end

    # THE GATE THAT COULD NOT LOSE (dr-w22-s1 / charter D386). The order above was
    # asserted only over `scrub`/`strip_ansi` as BARE functions — nothing called
    # `humanize/1` with a colourised input, so both orders were green and the
    # shipped one leaked in clean cleartext on the unclassified terminal arm.
    #
    # FIXTURE RULE (D387), and it decides the verdict: the secret is NON-prefixed
    # and the CSI sits immediately LEFT of the key. A CSI in the VALUE position
    # (`api_key=\e[31m…`) or a provider-prefixed token (`sk-…`) is safe under BOTH
    # orders, so either fixture yields a GREEN test over a LIVE hole.
    test "humanize/1 itself redacts a colourised non-prefixed api_key — the order is pinned where it ships" do
      secret = "Ab3xQ9zK1mP7vT"
      line = "\e[31mapi_key=#{secret}\e[0m fetching graph corpus"

      humanized = FailureCopy.humanize(line)

      refute humanized =~ secret,
             "humanize/1 shipped a live credential in cleartext: #{inspect(humanized)}"

      assert humanized == "api_key=[redacted] fetching graph corpus"
    end

    # The residual, asserted rather than described, so the day someone closes it
    # this file tells them which guard to move. An OSC leaves a non-delimiter
    # byte flush against the key AFTER stripping, which re-blocks the lookbehind.
    test "RESIDUAL (open): an OSC that abuts the key still leaks under the fixed order" do
      secret = "Ab3xQ9zK1mP7vT"
      line = "\e]0;t\ainapi_key=#{secret}"

      assert FailureCopy.raw(line) == "inapi_key=#{secret}",
             "the OSC residual closed — delete this test and claim it in the epic"
    end

    # Order-INDEPENDENCE of the prefix clause, stated as a test so the claim in
    # the moduledoc is checkable: our own token closes under BOTH orders.
    test "a bppat_ token is redacted under either order — the prefix clause sees the token itself" do
      line = "\e[31mtoken=#{@bppat}\e[0m"

      refute line |> FailureCopy.scrub() |> FailureCopy.strip_ansi() =~ @bppat
      refute line |> FailureCopy.strip_ansi() |> FailureCopy.scrub() =~ @bppat
    end
  end

  describe "humanize/1 — where the scrub sits" do
    # PLACEMENT (a): POST-classification. The A/B on one input. Scrubbing FIRST
    # eats the `timeout` token before the cond can see it, so the string stops
    # reading as the network class — a live copy shift, not a hypothetical.
    test "post-cond, not pre-cond: 'client_secret=timeout' still classifies" do
      input = "client_secret=timeout"

      # POST-scrub (shipped): the class arm wins, and its literal output carries
      # no secret shape, so the scrub is a no-op over it.
      assert FailureCopy.humanize(input) == "A network step timed out. Retry usually fixes this."

      # PRE-scrub (mutation): scrub first, then classify — the classification is
      # gone and the person gets a bare redaction instead of the retry advice.
      assert input |> FailureCopy.scrub() |> FailureCopy.humanize() == "client_secret=[redacted]"
    end

    # PLACEMENT (b): the scrub WRAPS the cond. An unclassified remote capture
    # falls through the TERMINAL arm, so a scrub nested in the typed_refusal? arm
    # would be a no-op for exactly this string.
    test "an unclassified remote capture — the terminal arm — is scrubbed" do
      capture = "ssh: remote said Authorization: Bearer sk-live-9aB3xQ7zLmNpR4tV6wY2"

      refute FailureCopy.typed_refusal?(capture),
             "this probe only bites if the capture is NOT a typed refusal"

      assert FailureCopy.humanize(capture) ==
               "ssh: remote said Authorization: Bearer [redacted]"
    end

    # PLACEMENT (c): no laundering. The typed refusal keeps its E_* code and its
    # offending entry; only the credential inside it is replaced.
    test "a typed refusal carrying a secret keeps its E_* code and entry" do
      reason =
        ~s|the instance refused the deploy (HTTP 400): E_BAD_NAME — entry "cfg?token=sk-live-9aB3xQ7zLm" is refused|

      out = FailureCopy.humanize(reason)

      assert out =~ "E_BAD_NAME"
      assert out =~ "the instance refused the deploy (HTTP 400)"
      assert out =~ "is refused"
      assert out =~ "[redacted]"
      refute out =~ "sk-live-9aB3xQ7zLm"

      # NOT rewritten into a class sentence.
      refute out =~ "A capacity or quota limit was reached at the hosting provider"
    end

    test "matched class copy is unchanged by the scrub (every arm returns a literal)" do
      assert FailureCopy.humanize("exceeded max provision attempts (3)") ==
               "This didn't finish after several attempts. Try again in a moment."

      assert FailureCopy.humanize("SERVER_LIMIT_EXCEEDED") ==
               "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."
    end

    test "nil and non-binaries still pass through" do
      assert FailureCopy.humanize(nil) == nil
      assert FailureCopy.humanize(42) == 42
    end
  end

  describe "strip_ansi/1 — the terminal bytes nothing was removing" do
    # A VERBATIM astro capture from the control plane (2026-08-05): a
    # `BUILD failed (exit 12)` reason with real 0x1B bytes, exactly as the build
    # PTY wrote them. 1,366 of 17,395 failed rows carry these, and until this
    # helper NOTHING stripped them: not this module, not the CLI's siteFailure,
    # not the console's failureCopy(). They render as literal `[31m[1m`.
    @astro_build_12 "BUILD failed (exit 12): \e[31m\e[1m04:34:24\e[22m [ERROR] [build]\e[39m Caught error rendering /graph.json: Error: graph corpus fetch failed: 403"

    test "a real astro BUILD-exit-12 reason emerges with no escape bytes and its words intact" do
      # The bytes are genuinely there in the fixture — a test over a fixture that
      # merely contains the four-character text `\\x1B` proves nothing (the
      # literal text appears in ZERO rows; the bytes appear in 1,366).
      assert String.contains?(@astro_build_12, "\e")

      out = FailureCopy.strip_ansi(@astro_build_12)

      refute String.contains?(out, "\e")
      refute out =~ ~r/\[\d+m/

      assert out ==
               "BUILD failed (exit 12): 04:34:24 [ERROR] [build] Caught error rendering /graph.json: Error: graph corpus fetch failed: 403"
    end

    test "strips CSI, OSC and bare two-byte escapes; leaves ordinary brackets alone" do
      assert FailureCopy.strip_ansi("\e[2Kclearing") == "clearing"
      assert FailureCopy.strip_ansi("\e]0;title\atext") == "text"
      assert FailureCopy.strip_ansi("a\e=b") == "ab"

      # A square bracket is not an escape. Build logs are full of them.
      assert FailureCopy.strip_ansi("[ERROR] [build] step [3/7] failed") ==
               "[ERROR] [build] step [3/7] failed"
    end

    test "idempotent, and nil / non-binaries pass through" do
      once = FailureCopy.strip_ansi(@astro_build_12)
      assert FailureCopy.strip_ansi(once) == once
      assert FailureCopy.strip_ansi(nil) == nil
      assert FailureCopy.strip_ansi(42) == 42
      assert FailureCopy.strip_ansi("") == ""
    end

    test "humanize/1 strips LAST, so the classifier still sees the raw prefix" do
      # The escape run sits between the producer's template and the text, so
      # stripping before classification would change what the cond reads.
      out = FailureCopy.humanize(@astro_build_12)
      refute String.contains?(out, "\e")
      assert out =~ "BUILD failed (exit 12)"
    end

    test "a class-sentence arm is untouched by the strip" do
      assert FailureCopy.humanize("exceeded max provision attempts (3)") ==
               "This didn't finish after several attempts. Try again in a moment."
    end
  end
end

defmodule BarkparkCloud.FailureCopyDeploymentDetailTest do
  @moduledoc """
  cch-w28-s5 — THE LAST RAW `detail` KEY ON THE DEPLOY PAYLOAD.

  `deployment_json/1` humanizes `failure_reason` and — since cch-w27-s2 — folds
  `console[].detail` and `stages[].detail` through `Sites.Deploy.stage_caption/2`.
  Its own TOP-LEVEL `detail:` key was the one boundary left: it read
  `FailureCopy.scrub/1`, so the live sub-caption under the status pill shipped
  raw provider jargon in the SAME payload whose `failure_reason` had already been
  classified. This pins the fold at the `deployment_json` level — a row built
  DIRECTLY (`%Deployment{status: …, detail: …}`), never by racing the worker,
  whose window is sub-second and whose fixture would be flaky.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, FailureCopy, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # A refused-connection capture as a box actually folds it — the class this
  # slice split out, so the assertion moves only if BOTH halves shipped.
  @raw_refused "dial tcp 10.0.0.4:4000: connect: connection refused"
  @refused_copy "Nothing is listening on the port we dialled — the service on the box is down or hasn't finished starting. Check the instance's health in the console."

  defp setup_site do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    {:ok, token} = Accounts.create_user_session_token(user)
    {site, token}
  end

  defp deployment_row(site, attrs) do
    Repo.insert!(struct(%Deployment{site_id: site.id, environment: "production"}, attrs))
  end

  # GET /v1/sites/:id/deployments is the list `deployment_json/1` renders
  # UNWRAPPED — no `site_deployment_json/3` stage overlay in the way.
  defp rendered(site, token) do
    conn = conn(:get, "/v1/sites/#{site.id}/deployments")
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    conn = Router.call(conn, @opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["deployments"]
  end

  test "a FAILED row's top-level detail is CLASSIFIED, not merely scrubbed" do
    {site, token} = setup_site()

    deployment_row(site, %{status: "failed", detail: @raw_refused, failure_reason: @raw_refused})

    assert [%{"detail" => detail, "failure_reason" => reason}] = rendered(site, token)

    # The whole point: ONE string, ONE story, in ONE payload.
    assert detail == @refused_copy
    assert reason == @refused_copy
    refute detail =~ "dial tcp"
  end

  test "a non-failed row's top-level detail is still SCRUBBED, never classified" do
    {site, token} = setup_site()

    raw = "BUILD npm install — Authorization: Bearer sk-live-9Xq2LmT4vB7nR1zC8kW5"
    deployment_row(site, %{status: "building", detail: raw})

    assert [%{"detail" => detail}] = rendered(site, token)

    # `stage_caption/2`'s non-failed arm IS the scrub the old code applied — the
    # narration survives, the credential does not, and no class sentence is
    # invented for a build that has not failed.
    assert detail =~ "BUILD npm install"
    assert detail =~ "[redacted]"
    refute detail =~ "sk-live-9Xq2LmT4vB7nR1zC8kW5"
  end

  test "a BUILDING row carrying jargon is NOT rewritten into a failure class" do
    {site, token} = setup_site()

    deployment_row(site, %{status: "building", detail: @raw_refused})

    assert [%{"detail" => detail}] = rendered(site, token)
    assert detail == FailureCopy.scrub(@raw_refused)
    refute detail == @refused_copy
  end

  test "a nil detail stays nil" do
    {site, token} = setup_site()
    deployment_row(site, %{status: "queued", detail: nil})

    assert [%{"detail" => nil}] = rendered(site, token)
  end

  ## ---------------------------------------------------------------------------
  ## THE CREDENTIAL ARM NAMES NO PARTY (wave 40 S6)
  ## ---------------------------------------------------------------------------
  ##
  ## The auth arm was the capacity arm's untreated twin: a bare two-token
  ## substring test whose copy named a provider ("the hosting provider"), whose
  ## credential it was ("our credentials"), and an agent working the problem
  ## ("We're on it — try again shortly"). `humanize/1` is arity 1; none of the
  ## three is derivable from the string.
  ##
  ## This corpus is the guard that can lose. Three captures MUST NOT reach a
  ## sentence that names a party, asserts an agent or prescribes a retry; the
  ## fourth is the must-CLEAR control — the NARROWED Azure RBAC clause, which
  ## already discriminates and must keep classifying exactly as it did.

  # deploy/site-deploy.sh:968 (READ-ONLY) — the build's own FATAL line. The
  # rejected credential is the USER'S site read token; no hosting provider is
  # anywhere in this story.
  @probe_site_token "FATAL: 401 Unauthorized from https://guerrilla.barkpark.cloud/w/acme/p/blog — the site read token is invalid"

  # A DISK-FULL build whose only crime is a framework error-page path. The word
  # `unauthorized` is a PATH SEGMENT — the same self-satisfaction shape wave 25
  # narrowed out of the DNS clause, and `typed_refusal?/1` does not cover it
  # (no `E_*` code, no box-refusal prefix).
  @probe_disk_full "BUILD failed (exit 1): copying dist/errors/unauthorized/index.html failed: no space left on device"

  # A private npm registry rejecting the user's own npm token.
  @probe_npm "npm ERR! 401 Unauthorized - GET https://registry.npmjs.org/@acme/private"

  # THE MUST-CLEAR CONTROL: the narrowed Azure clause (failure_copy.ex, checked
  # before the credential arm) owns this one and names the exact portal fix.
  @probe_azure "az: AuthorizationFailed - invalid token for subscription"

  # Added at review of cch-w40-s6. The path guard originally excluded ANY
  # trailing dot, so a producer that simply ended a SENTENCE fell out of the
  # class and passed through unclassified — a narrowing nobody asked for, in a
  # shape at least as common as the path it was aimed at. These two must-FLAG
  # beside the disk-full must-CLEAR: a dot before whitespace or end-of-capture is
  # punctuation, a dot before a non-space is a filename.
  @probe_sentence_dot "deploy step failed: the registry said Unauthorized."
  @probe_mid_sentence_dot "release refused: unauthorized. re-run after rotating the token"

  describe "humanize/1 — the credential arm names no party" do
    test "the Azure RBAC control still classifies to its own copy" do
      assert FailureCopy.humanize(@probe_azure) ==
               "Your Azure service principal is missing a role. In the Azure Portal → Subscriptions → your subscription → Access control (IAM) → Add role assignment, grant it the Contributor role, then reconnect."
    end

    # RE-POINTED by task-fda5b6f19f1e06c9. `@probe_site_token` moved OUT of this
    # loop and into its own assertion below: it is the one capture whose owner
    # and remedy the producer's own bytes carry, so it now gets a sentence that
    # names them. This loop keeps the ANONYMOUS captures, which is what the
    # no-party discipline was always about — `@probe_npm` names no owner, so a
    # sentence that claimed one would still be inventing it.
    test "an ANONYMOUS rejected credential is reported WITHOUT naming a party, an agent or a retry" do
      for probe <- [@probe_npm] do
        out = FailureCopy.humanize(probe)

        # It still classifies — the arm is narrowed, not deleted.
        refute out == FailureCopy.scrub(probe), "#{probe} stopped classifying"
        assert out =~ "credential", "#{probe} lost the credential class: #{out}"

        # NO PARTY.
        refute out =~ ~r/hosting provider/i, "names a party: #{out}"
        refute out =~ ~r/\bHetzner\b/i, "names a party: #{out}"
        refute out =~ ~r/\bAzure\b/i, "names a party: #{out}"

        # NO AGENT — nobody in this seam is "on it".
        refute out =~ ~r/we're on it/i, "asserts an agent: #{out}"
        refute out =~ ~r/\bour credentials\b/i, "asserts whose credential: #{out}"

        # NO REMEDY IT NEVER DETERMINED — a rejected token is not cleared by
        # waiting, and this predicate cannot know whether a retry can work.
        refute out =~ ~r/try again/i, "prescribes a retry: #{out}"
        refute out =~ ~r/\bshortly\b/i, "prescribes a retry: #{out}"
      end
    end

    test "a disk-full build is NOT a credential rejection because a PATH says unauthorized" do
      out = FailureCopy.humanize(@probe_disk_full)

      refute out =~ "credential", "a path slug satisfied the credential predicate: #{out}"

      refute out =~ ~r/hosting provider/i,
             "a path slug satisfied the credential predicate: #{out}"

      # It lands where an unclassifiable capture belongs: through, verbatim.
      assert out == FailureCopy.scrub(@probe_disk_full)
      assert out =~ "no space left on device"
    end

    test "a sentence-final dot is punctuation, not a path segment" do
      for probe <- [@probe_sentence_dot, @probe_mid_sentence_dot] do
        out = FailureCopy.humanize(probe)

        assert out =~ "credential",
               "a producer that ended a sentence lost the credential class: #{out}"

        refute out == FailureCopy.scrub(probe), "#{probe} stopped classifying"
      end

      # …and the guard it relaxes still holds: a dot followed by a NON-space is
      # still a filename, and still not a credential rejection.
      assert FailureCopy.humanize(
               "BUILD failed: writing unauthorized.html failed: no space left on device"
             ) ==
               FailureCopy.scrub(
                 "BUILD failed: writing unauthorized.html failed: no space left on device"
               )
    end

    test "the classified copy is idempotent under a second pass" do
      for probe <- [@probe_site_token, @probe_npm] do
        once = FailureCopy.humanize(probe)
        assert FailureCopy.humanize(once) == once, "second pass reclassified: #{once}"
      end
    end
  end

  ## ---------------------------------------------------------------------------
  ## THE SITE READ TOKEN 401 NAMES THE TOKEN AND THE FIX (task-fda5b6f19f1e06c9)
  ## ---------------------------------------------------------------------------
  ##
  ## Wave 40 S6 stopped the credential arm LYING (it named a hosting provider
  ## that is not in this story). It did not make it TELL: the one capture whose
  ## owner and remedy the producer already spells out still received the same
  ## say-nothing sentence as an anonymous 401, and the fix a person can actually
  ## perform reached them only in the raw line folded one element below.
  ##
  ## The clause is keyed on `deploy/site-deploy.sh`'s OWN BYTES. These tests read
  ## both shells at test time and extract the FATAL line with a regex, so the key
  ## is never a hand-typed string that can drift away from its producer in
  ## silence — the day a shell rewords, this file reds.

  defp shell_fatal_line!(rel) do
    shell = File.read!(Path.expand(rel, File.cwd!()))
    [[_, line]] = Regex.scan(~r/echo "(FATAL: 401 Unauthorized[^"]*)" >&2/, shell)
    line
  end

  @site_token_copy "This site's Barkpark read token was rejected, so the build couldn't fetch its content. Mint a fresh read token for the site in Barkpark, save it on the site, then deploy the site again."

  describe "humanize/1 — a site read token 401 names the token and the fix" do
    test "the producer's OWN bytes classify to the site-token sentence, read out of both shells" do
      for rel <- ["../deploy/site-deploy.sh", "../deploy/site-deploy-node.sh"] do
        line = shell_fatal_line!(rel)

        # The precondition: the clause's key really is IN the producer's bytes.
        assert line =~ "the site read token is invalid",
               "#{rel} reworded its FATAL line — re-derive the clause key: #{line}"

        assert FailureCopy.humanize(line) == @site_token_copy,
               "#{rel}'s own capture did not reach the site-token clause: " <>
                 FailureCopy.humanize(line)
      end
    end

    test "the committed probe reaches the SAME sentence, and it names the token AND the fix" do
      out = FailureCopy.humanize(@probe_site_token)

      assert out == @site_token_copy

      # THE TOKEN, in the classified sentence itself — not only in the raw line.
      assert out =~ ~r/read token/i, "the class does not name the read token: #{out}"

      # THE FIX, likewise.
      assert out =~ ~r/mint a fresh read token/i, "the class names no fix: #{out}"

      # It did NOT regress into the party/agent copy wave 40 removed.
      refute out =~ ~r/hosting provider/i, "names a party: #{out}"
      refute out =~ ~r/\bHetzner\b/i, "names a party: #{out}"
      refute out =~ ~r/\bAzure\b/i, "names a party: #{out}"
      refute out =~ ~r/we're on it/i, "asserts an agent: #{out}"
      refute out =~ ~r/\bour credentials\b/i, "asserts whose credential: #{out}"

      # …and the remedy it names is the TOKEN, not a bare wait-and-retry.
      refute out =~ ~r/try again shortly/i, "prescribes a bare retry: #{out}"
    end

    test "it is a NARROWING, not a bypass: the anonymous credential arm still fires" do
      # No site-token bytes anywhere — this must keep the say-nothing class.
      out = FailureCopy.humanize(@probe_npm)

      assert out =~ "credential", "the generic credential class stopped firing: #{out}"
      refute out == @site_token_copy, "a generic 401 was captured by the site-token clause"
      refute out =~ ~r/read token/i, "the generic class invented an owner: #{out}"

      # The other generic shapes the wave-40 corpus and the unit suite pin.
      for probe <- [
            "hcloud: unauthorized (401)",
            "provider returned invalid token",
            @probe_sentence_dot,
            @probe_mid_sentence_dot
          ] do
        assert FailureCopy.humanize(probe) =~ "credential",
               "#{probe} lost the credential class"

        refute FailureCopy.humanize(probe) == @site_token_copy,
               "#{probe} was captured by the site-token clause"
      end
    end

    test "the Azure RBAC clause is UNTOUCHED — the must-clear control still classifies first" do
      assert FailureCopy.humanize(@probe_azure) ==
               "Your Azure service principal is missing a role. In the Azure Portal → Subscriptions → your subscription → Access control (IAM) → Add role assignment, grant it the Contributor role, then reconnect."

      # And the RBAC clause still wins over BOTH credential clauses when a
      # capture carries Azure's token alongside a site-token phrase — ordering,
      # not luck.
      assert FailureCopy.humanize("az: AuthorizationFailed — the site read token is invalid") =~
               "Azure service principal is missing a role"
    end

    test "the path guard survives: a slug is still not a site-token rejection" do
      assert FailureCopy.humanize(@probe_disk_full) == FailureCopy.scrub(@probe_disk_full)
      refute FailureCopy.humanize(@probe_disk_full) =~ ~r/read token/i
    end

    test "the site-token copy is idempotent under a second pass" do
      assert FailureCopy.humanize(@site_token_copy) == @site_token_copy
    end
  end
end
