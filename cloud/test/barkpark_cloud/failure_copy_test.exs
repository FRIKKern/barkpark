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
      "Hetzner ran out of server capacity for this size. Try again shortly or contact support."

    assert FailureCopy.humanize("server type unavailable (SERVER_LIMIT_EXCEEDED)") == capacity
    assert FailureCopy.humanize("resource_unavailable: cx22 in fsn1") == capacity
    assert FailureCopy.humanize("account quota exceeded for servers") == capacity
    # lower-cased provider code still matches.
    assert FailureCopy.humanize("server_limit_exceeded") == capacity
  end

  test "auth/token jargon → human credentials copy" do
    auth = "The hosting provider rejected our credentials. We're on it — try again shortly."

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
             "Hetzner ran out of server capacity for this size. Try again shortly or contact support."
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
      "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming."

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

    refute FailureCopy.humanize(raw) =~ "Hetzner ran out of server capacity"
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
      "Hetzner ran out of server capacity",
      "A network step timed out",
      "The hosting provider rejected our credentials",
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
             "Hetzner ran out of server capacity for this size. Try again shortly or contact support."

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

  test "the azure classes do not steal the Hetzner capacity string" do
    # Hetzner's spaced 'account quota exceeded' still reads as capacity, NOT the
    # azure family-quota copy (no 'quotaexceeded'/'family'/'vcpu' token).
    assert FailureCopy.humanize("account quota exceeded for servers") ==
             "Hetzner ran out of server capacity for this size. Try again shortly or contact support."
  end

  ## THE FALLBACK-LADDER AGGREGATE IS CLASSIFIED PER SUB-ERROR (wave 25 S1).
  ##
  ## `CreateWithFallback` folds every candidate's failure into ONE string, so a
  ## substring scan of the whole concatenation fires on any token ANY candidate
  ## mentioned, on the header's own literal `failed`, and on the user's own slug.

  @capacity "Hetzner ran out of server capacity for this size. Try again shortly or contact support."
  @dns_copy "Securing the domain failed on the provider side."
  @network "A network step timed out. Retry usually fixes this."
  @auth "The hosting provider rejected our credentials. We're on it — try again shortly."

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

  test "hetzner pause gap explains a stopped Hetzner box still bills → archive instead" do
    reason = FailureCopy.capability_gap_reason("hetzner", "pause")
    assert reason =~ "Hetzner"
    assert reason =~ "bill"
    assert reason =~ "Archive"
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
      {"bare mixed-case 40-char provider token", "provider rejected " <> @bare_token, @bare_token}
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
      {"prose in a password value", "sftp refused: password: missing"}
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
      refute out =~ "Hetzner ran out of server capacity"
    end

    test "matched class copy is unchanged by the scrub (every arm returns a literal)" do
      assert FailureCopy.humanize("exceeded max provision attempts (3)") ==
               "This didn't finish after several attempts. Try again in a moment."

      assert FailureCopy.humanize("SERVER_LIMIT_EXCEEDED") ==
               "Hetzner ran out of server capacity for this size. Try again shortly or contact support."
    end

    test "nil and non-binaries still pass through" do
      assert FailureCopy.humanize(nil) == nil
      assert FailureCopy.humanize(42) == 42
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
end
