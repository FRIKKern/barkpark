defmodule BarkparkCloud.ClaimPayloadManifest.Go do
  @moduledoc """
  The Side-B extractor: the `json:"…"` tag set reachable from the type(s)
  actually unmarshalled AT A NAMED `json.Unmarshal` CALL SITE in
  `internal/provisioner/`.

  PER-DECODE-SITE, and both rivals were measured and refused:

    * a PACKAGE-WIDE UNION (the shape `payload_key_set_census_test.exs` uses,
      correctly, for its own question) run over `internal/provisioner` yields 38
      tags — and `template`/`agent_token`/`kind`/`credentials` are all in it,
      because they are `JobSpec` fields, while NONE of them is on
      `SupportJobSpec`. A union arm therefore reports the SUPPORT claim clean on
      four keys the support decoder provably cannot see. Worse, `env` is absent
      from that union only because of ONE line — the sole `json:"env"` in the
      package is in `bootstrap_wiring_test.go`, a TEST file — so a union that
      stopped rejecting `_test.go` would false-green the crown itself.
    * PURE PER-STRUCT (keyed on a type NAME) false-REDS six live keys:
      `worker.go` decodes the support claim a SECOND time into an INLINE
      ANONYMOUS struct — the commented "TOLERATED DIALECT" — which rescues
      `job_id`/`claim_token`/`name`/`slug`/`region`/`server_type` and is
      invisible to any name-keyed scan.

  So a site is `{file, line, unmarshal target}` and its tag set is the TOP-LEVEL
  tags of the target type — named, or inline-anonymous. Top-level only: the
  question this manifest asks is about the claim payload's top-level keys, and a
  nested map is its own contract with its own struct.
  """

  @doc "Every non-test Go source in `dir`, as `%{basename => contents}`."
  @spec sources(binary) :: %{binary => binary}
  def sources(dir) do
    dir
    |> Path.join("*.go")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "_test.go"))
    |> Map.new(&{Path.basename(&1), File.read!(&1)})
  end

  @doc """
  `%{tag => go_type}` for one NAMED struct's own fields, or nil when the struct
  is not declared in `src`.
  """
  @spec struct_fields(binary, binary) :: %{binary => binary} | nil
  def struct_fields(src, name) do
    case Regex.run(~r/^type #{Regex.escape(name)} struct \{\n(.*?)\n\}$/ms, src,
           capture: :all_but_first
         ) do
      [body] -> fields(body)
      _ -> nil
    end
  end

  @doc """
  `%{tag => go_type}` for an INLINE ANONYMOUS struct bound as `var <name> struct
  {…}`, or nil when no such declaration exists. This is the only way the
  tolerated-dialect fallback is visible at all.
  """
  @spec inline_struct_fields(binary, binary) :: %{binary => binary} | nil
  def inline_struct_fields(src, var) do
    case Regex.run(~r/\n([ \t]*)var #{Regex.escape(var)} struct \{\n(.*?)\n\1\}/s, src,
           capture: :all_but_first
         ) do
      [_indent, body] -> fields(body)
      _ -> nil
    end
  end

  @doc """
  One top-level Go function's line span, as `{first_line, last_line}`, or nil.
  The span runs from the `func …` signature to the next column-0 `}`.

  This — not a bare line number — is what a decode site is pinned INSIDE. A
  strict line-equality pin reds on every unrelated edit above the call in a file
  that took 48 commits in 60 days, and a guard that cries wolf gets its numbers
  bumped without thought, which is how a pin dies. Pinning the enclosing
  FUNCTION still loses exactly when it should: the decode moving out of
  `claimSupport`, or the function being renamed or deleted.
  """
  @spec func_span(binary, binary) :: {pos_integer, pos_integer} | nil
  def func_span(src, signature) do
    lines = String.split(src, "\n")

    case Enum.find_index(lines, &(&1 == signature)) do
      nil ->
        nil

      idx ->
        close =
          lines
          |> Enum.drop(idx + 1)
          |> Enum.find_index(&(&1 == "}"))

        close && {idx + 1, idx + 1 + close + 1}
    end
  end

  @doc """
  The 1-based line numbers in `src` carrying `json.Unmarshal(…, &<var>)`. A site
  whose call left its declared function is a site that MOVED, and a manifest
  attributing a discarded key to a place the decode no longer happens is a
  manifest measuring nothing.
  """
  @spec unmarshal_lines(binary, binary) :: [pos_integer]
  def unmarshal_lines(src, var) do
    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} ->
      String.contains?(line, "json.Unmarshal(") and String.contains?(line, "&#{var}")
    end)
    |> Enum.map(fn {_line, n} -> n end)
  end

  @doc "Every `json.Unmarshal(` line number in `src` — the anti-vacuity control."
  @spec all_unmarshal_lines(binary) :: [pos_integer]
  def all_unmarshal_lines(src) do
    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, "json.Unmarshal(") end)
    |> Enum.map(fn {_line, n} -> n end)
  end

  # `Name  Type  `json:"tag,opts"`` — one struct field per line. Go field types in
  # these structs carry no spaces (`map[string]string`, `*BundleRef`, `string`),
  # so a whitespace split is exact rather than approximate.
  defp fields(body) do
    ~r/^\s*\w+\s+(\S+)\s+`[^`]*json:"([^"]*)"/m
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [type, tag] -> {tag |> String.split(",") |> List.first(), type} end)
    |> Enum.reject(fn {tag, _type} -> tag in ["", "-"] end)
    |> Map.new()
  end
end

defmodule BarkparkCloud.Web.ClaimPayloadManifestTest do
  @moduledoc """
  THE CP→WORKER CLAIM PAYLOAD MANIFEST (cch-w53-s2, charter D607/D608).

  Go's `encoding/json` DISCARDS an unmodelled key in silence. `DisallowUnknownFields`
  appears ZERO times in `internal/provisioner` across its seven decode sites. So the
  control plane can ship a key on a claim — including a user's decrypted secret —
  and the worker will drop it on the floor with no error, no log line and no
  failing test anywhere in either tree. That is the crown of wave 53, and it is a
  CLASS, not a one-off: this file is the instrument that outlives the crown.

  ## Sibling of, never an extension of, `payload_key_set_census_test.exs`

  That census answers a different question with the OPPOSITE semantics (its UNREAD
  arm is a deliberate package-wide UNION, its Go root is `internal/cloudclient`
  ONLY, and its `@go_tag_floor` is an exact equality over that one root), and it
  is fenced to the in-flight deploy-reliability epic — 20+ of its `@known_open`
  rows cite `dr-*` trackers. Hoisting a shared extractor would edit it; it is a
  known concurrent-PR collision point. So this file duplicates a small extractor
  on purpose and edits nothing over there.

  ## The two sides

    * SIDE A — a REAL 200. `Plug.Test` drives `POST /v1/internal/provision-jobs/claim`,
      `/resurrect-jobs/claim` and `/support-jobs/claim` with the worker token and
      censuses `Jason.decode!(conn.resp_body)`. Never an AST walk: the census's
      Side-A extractor reads `claim_json/2` perfectly but returns ONE key for each
      DERIVED claim (`support`, `bundle_ref`), because its one-level pipe walk
      cannot follow a pipe whose SOURCE is a function call — so both derived
      claims would lose all 11 inherited keys and the arm would report phantoms
      instead of divergences. Fixtures exercise the OPTIONAL keys (an azure
      barkpark for `kind`+`credentials`, a resurrect job for `bundle_ref`, a team
      env var for `env`, a template for `template`) or the arm goes vacuous on
      exactly the keys most likely to drift.
    * SIDE B — PER-DECODE-SITE (see `ClaimPayloadManifest.Go`), never a package
      union and never a bare per-struct map.

  ## The two allowlists, and the custody type gate

    * `@known_open` — "this key IS a defect, tracked HERE." Asserted by MapSet
      EQUALITY so the guard is GREEN ON LANDING while the defect is present and
      tracked, and REDS the moment a key stops being discarded — the row must then
      be deleted, which is the bookkeeping the equality exists to force.
    * `@reserved` — "the plane ships this AHEAD of the worker on purpose, and
      NOTHING tells a user it arrived." Forward compatibility is real on this
      payload ("an OLD worker simply ignores the key" is written into the server
      three times), so a strict `DisallowUnknownFields` guard would be WRONG. A
      reserved row therefore carries FOUR MECHANICAL conjuncts, never prose:
      R1 decode-site scope, R2 a NO-USER-PROMISE read taken by RUNNING the shipped
      `app.js` in a `node:vm` sandbox (a denial regex was tried and matched two
      unrelated webhook-delivery lines, handing a future author a free
      "false positive" exit), R3 a byte-exact pin of the emitting server comment,
      R4 set equality. It is EMPTY today, and its mechanism is still exercised
      every run.
    * `@custody_ineligible` — THE CUSTODY TYPE GATE, its own pinned list with its
      own equality assertion. A key whose value is a USER-SUPPLIED SECRET may
      never be reserved at all: it must be consumed or removed. Without this gate
      the next env-shaped key gets a reserved row with all four conjuncts GREEN —
      because this wave's sibling slice deletes the console copy R2 and R3 read —
      and the exposure recurs behind a fully honest-looking guard.

  ## What this guard does NOT prove

  That a field EXISTING on a Go struct means anything READS it. `job.Template`
  having a home in `JobSpec` is not evidence that the worker does anything with
  it. Read-reachability is a DIFFERENT arm and is deliberately out of scope —
  said here because silence would let a future reader take a green from this file
  as delivery, which is the exact mistake that produced the crown.

  Also out of scope this wave: the deprovision and attach-domain claims have
  DECLARED decode sites here (their pins and tag sets are live, so a moved site
  reds) but no Side-A pairing — filed rather than faked.

  ## Why this file is what enforces the dispatcher declaration

  It reads the Go package through a SINGLE STRING LITERAL relative path (see
  `@provisioner`), which `scripts/cloud-path-escape-check.sh` resolves as a
  repo-root read of the Cloud suite; that ratchet fails unless
  `internal/provisioner/**` is in `CLOUD_PATHS`. The literal FORM is load-bearing
  and is asserted below: the ratchet greps a `"../…"` literal out of the source,
  so the identical directory written as a `Path.join` segment list is INVISIBLE
  to it — measured, the census is unchanged and the ratchet exits 0 — which would
  ship this manifest with a dispatcher that never runs it, under a green Cloud
  gate.

  `ARM 6` therefore asserts BOTH that the ratchet's census carries the package
  AND that the attribution line in THIS file is byte-exactly the single-literal
  form — because the census arm alone is defeated by a prose mention: written out
  in this very docstring, a quoted relative path would keep the census green
  while the real read was a segment list. That is measured, not hypothetical: it
  is why no quoted `..`-path appears in this moduledoc
  (cch-w53-bl-escape-ratchet-is-literal-shaped).
  """

  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.ClaimPayloadManifest.Go
  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  # THE GO ROOT — a SINGLE STRING LITERAL, deliberately (see moduledoc + ARM 6).
  # Never a Path.join segment list: that resolves to the identical directory and
  # is invisible to the escape ratchet.
  @provisioner Path.expand("../../../../internal/provisioner", __DIR__)
  @repo_root Path.expand("../../../..", __DIR__)
  @escape_check Path.expand("../../../../scripts/cloud-path-escape-check.sh", __DIR__)
  @router Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @app_js Path.expand("../../../priv/static/app.js", __DIR__)

  @azure_creds %{
    "tenant_id" => "11111111-1111-1111-1111-111111111111",
    "client_id" => "22222222-2222-2222-2222-222222222222",
    "client_secret" => "s3cr3t-value",
    "subscription_id" => "33333333-3333-3333-3333-333333333333"
  }

  # ---------------------------------------------------------------------------
  # THE DECODE SITES — `{file, line, unmarshal target}`, re-pinned every run.
  # ---------------------------------------------------------------------------
  # `func` is the MECHANICAL pin and `line` is the documented location the
  # @known_open rows quote. "Reserved/discarded AT THIS SITE" is a claim about a
  # place in the worker, not a vague "unknown somewhere", so the site must be
  # provable — but a strict line-EQUALITY pin reds on every unrelated edit above
  # the call in a file that took 48 commits in 60 days, and a guard that cries
  # wolf gets its numbers bumped without thought, which is how a pin dies. So the
  # assertion is: exactly one `json.Unmarshal(…, &var)` INSIDE the pinned
  # function, and the documented line inside that function's span. Both lose
  # exactly when they should — the decode leaving the function, the function
  # being renamed, or the site forking into two.
  @sites [
    %{
      id: "provision",
      file: "worker.go",
      line: 917,
      func: "func (w *Worker) claim(ctx context.Context) (JobSpec, bool, error) {",
      var: "job",
      type: {"worker.go", "JobSpec"},
      note: "claim() — the provision drain"
    },
    %{
      id: "resurrect",
      file: "worker.go",
      line: 1460,
      func:
        "func (w *Worker) claimResurrect(ctx context.Context) (resurrectClaimSpec, bool, error) {",
      var: "spec",
      type: {"restore_driver.go", "resurrectClaimSpec"},
      note: "claimResurrect() — bundle_ref is a STRING here, not JobSpec's *BundleRef"
    },
    %{
      id: "support",
      file: "worker.go",
      line: 1603,
      func: "func (w *Worker) claimSupport(ctx context.Context) (SupportJobSpec, bool, error) {",
      var: "spec",
      type: {"support.go", "SupportJobSpec"},
      note: "claimSupport() — the PDF-D83 nested {job,barkpark,support} envelope"
    },
    %{
      id: "support-dialect",
      file: "worker.go",
      line: 1622,
      func: "func (w *Worker) claimSupport(ctx context.Context) (SupportJobSpec, bool, error) {",
      var: "flat",
      inline: "flat",
      note:
        "claimSupport()'s TOLERATED DIALECT second decode — an INLINE ANONYMOUS struct no name-keyed scan can see"
    },
    %{
      id: "deprovision",
      file: "worker.go",
      line: 1165,
      func:
        "func (w *Worker) claimDeprovision(ctx context.Context) (DeprovisionSpec, bool, error) {",
      var: "spec",
      type: {"deprovision.go", "DeprovisionSpec"},
      note: "claimDeprovision() — DECLARED, no Side-A pairing this wave"
    },
    %{
      id: "attach-domain",
      file: "worker.go",
      line: 1281,
      func:
        "func (w *Worker) claimAttachDomain(ctx context.Context) (AttachDomainSpec, bool, error) {",
      var: "spec",
      type: {"worker.go", "AttachDomainSpec"},
      note: "claimAttachDomain() — DECLARED, no Side-A pairing this wave"
    }
  ]

  # Which decode site(s) receive each claim's bytes. The support claim is decoded
  # TWICE from the SAME response body, so its received set is the union of those
  # two sites — and of those two sites only.
  @claim_sites %{
    "provision" => ["provision"],
    "resurrect" => ["resurrect"],
    "support" => ["support", "support-dialect"]
  }

  # ---------------------------------------------------------------------------
  # @known_open — FIVE rows. A key the plane emits and the worker DISCARDS, which
  # is a DEFECT, tracked at the named bp task. MapSet EQUALITY (ARM 1).
  # ---------------------------------------------------------------------------
  @known_open [
    %{
      claim: "provision",
      key: "env",
      site: "internal/provisioner/worker.go:917 → provisioner.JobSpec",
      tracker:
        "cch-w52-bl-team-env-vars-are-shipped-in-the-provision-claim-and-nothing-on-the-box-consumes-them"
    },
    %{
      claim: "support",
      key: "env",
      site: "internal/provisioner/worker.go:1603 → SupportJobSpec (+:1622 inline dialect)",
      tracker: "cch-w53-bl-the-support-claim-discards-five-keys-including-a-live-agent-token"
    },
    %{
      claim: "support",
      key: "template",
      site: "internal/provisioner/worker.go:1603 → SupportJobSpec (+:1622 inline dialect)",
      tracker: "cch-w53-bl-the-support-claim-discards-five-keys-including-a-live-agent-token"
    },
    %{
      claim: "support",
      key: "kind",
      site: "internal/provisioner/worker.go:1603 → SupportJobSpec (+:1622 inline dialect)",
      tracker: "cch-w53-bl-the-support-claim-discards-five-keys-including-a-live-agent-token"
    },
    %{
      claim: "support",
      key: "credentials",
      site: "internal/provisioner/worker.go:1603 → SupportJobSpec (+:1622 inline dialect)",
      tracker: "cch-w53-bl-the-support-claim-discards-five-keys-including-a-live-agent-token"
    }
  ]

  # The RESURRECT claim's own open rows, kept as a SEPARATE pinned list because
  # the wave ruled `@known_open` at exactly six (the provision + support seam it
  # measured) — now FIVE, see below. Discovered by this manifest's first run and
  # filed the same hour; holding it in a second list rather than folding it in
  # keeps the ruled set auditable AND keeps the third claim from being silently
  # unmeasured.
  #
  # SIX → FIVE (cch-w53-bl-…-a-live-agent-token): the support claim's
  # `agent_token` row was deleted when the mint was removed from
  # `support_provision_claim_json/2`. Shrinking `@known_open` is exactly the
  # bookkeeping the equality exists to force, and it is only ever legal in the
  # same diff that fixes the defect it tracked.
  @resurrect_known_open [
    %{
      claim: "resurrect",
      key: "env",
      site: "internal/provisioner/worker.go:1460 → resurrectClaimSpec",
      tracker: "cch-w53-bl-the-resurrect-claim-discards-env-and-template"
    },
    %{
      claim: "resurrect",
      key: "template",
      site: "internal/provisioner/worker.go:1460 → resurrectClaimSpec",
      tracker: "cch-w53-bl-the-resurrect-claim-discards-env-and-template"
    }
  ]

  # ---------------------------------------------------------------------------
  # @reserved — EMPTY. Its mechanism is exercised every run regardless (ARM 5).
  # ---------------------------------------------------------------------------
  # A row is `%{claim, key, site, comment_pin, tracker}` and must satisfy ALL of:
  #   R1  `site` is one of the claim's declared decode sites AND the key is
  #       genuinely emitted-and-not-received there (never merely "unknown").
  #   R2  NO USER PROMISE: the shipped `cloud/priv/static/app.js` is EVALUATED in
  #       a `node:vm` sandbox and the key must be absent from the claim-key
  #       vocabulary the console exports on `__bpTestHook`. FAIL-CLOSED: if the
  #       console exports no such vocabulary, a reserved row cannot be blessed —
  #       reservation is the exceptional path and it is not available on a
  #       hand-wave.
  #   R3  the emitting server comment is pinned BYTE-EXACTLY, so re-arming the
  #       promise in new words reds the row.
  #   R4  set equality, which ARM 1 asserts for the whole discarded set.
  @reserved []

  # THE CUSTODY TYPE GATE — its own pinned list, its own equality assertion, so
  # removing a member is a diff a reviewer sees rather than a silent deletion in
  # the same commit that adds the row it unblocks. A key whose value is a
  # USER-SUPPLIED SECRET is INELIGIBLE FOR RESERVATION AT ALL: custody keys must
  # be consumed or removed, never allowlisted as "shipped ahead of the worker".
  @custody_ineligible ["env", "agent_token", "credentials"]

  # ---------------------------------------------------------------------------
  # Fixtures — a REAL 200 on each claim, exercising every optional key.
  # ---------------------------------------------------------------------------

  defp team! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, _} = Billing.subscribe(team, "supporter")
    # azure → the claim carries `kind` + the decrypted `credentials` 4-tuple.
    {:ok, _} = Registry.connect_provider(team, "azure", Jason.encode!(@azure_creds), label: "p")
    # a team env var → `env` is a NON-EMPTY map, so the crown's key is real bytes.
    {:ok, _} = Registry.put_env_var(team, %{key: "FOO", value: "bar", scope: "team"})
    team
  end

  defp worker_claim(path) do
    conn(:post, path, "{}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{@worker_token}")
    |> Router.call(@opts)
  end

  # The provision claim at its WIDEST: azure (kind + credentials), pinned
  # region/size, a template, and a non-empty env.
  defp provision_claim_body! do
    team = team!()
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{
        name: "Az #{n}",
        slug: "az-#{n}",
        provider: "azure",
        region: "westeurope",
        server_type: "Standard_B2s",
        template: "blog"
      })

    {:ok, _job} = Registry.enqueue_provision_job(bp)
    ok_body!(worker_claim("/v1/internal/provision-jobs/claim"), "provision")
  end

  # The resurrect claim = the full provision claim PLUS `bundle_ref`.
  defp resurrect_claim_body! do
    team = team!()
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{
        name: "Rz #{n}",
        slug: "rz-#{n}",
        provider: "azure",
        template: "blog"
      })

    {:ok, _job} = Registry.enqueue_resurrect_job(bp, "s3://bundles/rz-#{n}.tar.zst")
    ok_body!(worker_claim("/v1/internal/resurrect-jobs/claim"), "resurrect")
  end

  # The support claim = the full provision claim PLUS the pinned `support` map.
  # The support row is made azure + templated so the claim emits `kind`,
  # `credentials` and `template` — the four keys a per-struct-only arm would miss
  # and a union arm would call clean.
  defp support_claim_body! do
    team = team!()
    n = System.unique_integer([:positive])

    {:ok, main} = Registry.register_barkpark(team, %{name: "Main #{n}", slug: "main-#{n}"})

    main =
      main
      |> Ecto.Changeset.change(
        url: "https://main-#{n}.barkpark.cloud",
        host: "203.0.113.5",
        admin_token_encrypted: Vault.encrypt("admin-secret-#{n}"),
        bootstrap_workspace: "acme"
      )
      |> Repo.update!()

    {:ok, main} = main |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()

    {:ok, support} =
      Registry.register_support_barkpark(team, %{
        name: "Helper #{n}",
        slug: "helper-#{n}",
        parent_id: main.id
      })

    support =
      support |> Ecto.Changeset.change(provider: "azure", template: "blog") |> Repo.update!()

    {:ok, _job} = Registry.enqueue_support_provision_job(support)
    ok_body!(worker_claim("/v1/internal/support-jobs/claim"), "support")
  end

  defp ok_body!(conn, which) do
    assert conn.status == 200,
           "the #{which} claim did not 200 (got #{conn.status}) — a manifest whose Side A " <>
             "never reached a real payload measures NOTHING: #{inspect(conn.resp_body)}"

    Jason.decode!(conn.resp_body)
  end

  # ---------------------------------------------------------------------------
  # Side B helpers
  # ---------------------------------------------------------------------------

  defp go_sources, do: Go.sources(@provisioner)

  defp site(id), do: Enum.find(@sites, &(&1.id == id))

  # `%{tag => go_type}` for one decode site's target — named struct or inline
  # anonymous struct. Raises (reds) rather than returning empty: an extractor
  # that silently returns `%{}` reports every key as discarded, which is a red
  # for the wrong reason, or worse, greens an allowlist that grew to match it.
  defp site_fields(src_map, %{inline: var, file: file}) do
    case Go.inline_struct_fields(Map.fetch!(src_map, file), var) do
      nil ->
        flunk("no `var #{var} struct {…}` inline declaration found in #{file}")

      fields ->
        fields
    end
  end

  defp site_fields(src_map, %{type: {file, name}}) do
    case Go.struct_fields(Map.fetch!(src_map, file), name) do
      nil -> flunk("Go type #{name} is not declared in #{file}")
      fields -> fields
    end
  end

  defp site_keys(src_map, site_id), do: src_map |> site_fields(site(site_id)) |> Map.keys()

  # The union of the tag sets of the site(s) that decode ONE claim's bytes.
  defp received(src_map, claim) do
    @claim_sites
    |> Map.fetch!(claim)
    |> Enum.flat_map(&site_keys(src_map, &1))
    |> MapSet.new()
  end

  defp field_types(src_map, claim) do
    @claim_sites
    |> Map.fetch!(claim)
    |> Enum.reduce(%{}, fn id, acc -> Map.merge(acc, site_fields(src_map, site(id))) end)
  end

  defp discarded(body, src_map, claim) do
    MapSet.difference(MapSet.new(Map.keys(body)), received(src_map, claim))
  end

  defp rows_to_set(rows, claim) do
    rows |> Enum.filter(&(&1.claim == claim)) |> Enum.map(& &1.key) |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # ARM 1 — THE DISCARDED CENSUS. Emitted-minus-received == the allowlists.
  # ---------------------------------------------------------------------------

  describe "ARM 1 — every claim key the worker discards is an ALLOWLISTED, TRACKED row" do
    test "the PROVISION claim discards exactly {env}" do
      src = go_sources()
      body = provision_claim_body!()
      got = discarded(body, src, "provision")

      want =
        MapSet.union(rows_to_set(@known_open, "provision"), rows_to_set(@reserved, "provision"))

      assert_discarded("provision", got, want, body, src)
    end

    test "the SUPPORT claim discards exactly {env, template, kind, credentials}" do
      src = go_sources()
      body = support_claim_body!()
      got = discarded(body, src, "support")

      want =
        MapSet.union(rows_to_set(@known_open, "support"), rows_to_set(@reserved, "support"))

      assert_discarded("support", got, want, body, src)
    end

    test "the RESURRECT claim discards exactly {env, template}" do
      src = go_sources()
      body = resurrect_claim_body!()
      got = discarded(body, src, "resurrect")

      want =
        @resurrect_known_open
        |> rows_to_set("resurrect")
        |> MapSet.union(rows_to_set(@reserved, "resurrect"))

      assert_discarded("resurrect", got, want, body, src)
    end
  end

  defp assert_discarded(claim, got, want, body, src) do
    new_keys = MapSet.difference(got, want)
    stale_rows = MapSet.difference(want, got)

    assert MapSet.size(new_keys) == 0,
           "the #{claim} claim ships #{inspect(MapSet.to_list(new_keys))}, which NO decode site " <>
             "for this claim declares a field for — Go's encoding/json will drop it in silence, " <>
             "with no error, no log line and no other failing test. Either give the worker the " <>
             "field, stop emitting the key, or file it and add a @known_open row naming the " <>
             "tracker (a custody key — #{inspect(@custody_ineligible)} — may NEVER be reserved). " <>
             "emitted=#{inspect(Enum.sort(Map.keys(body)))} " <>
             "received=#{inspect(Enum.sort(MapSet.to_list(received(src, claim))))}"

    assert MapSet.size(stale_rows) == 0,
           "the #{claim} claim NO LONGER discards #{inspect(MapSet.to_list(stale_rows))} — the " <>
             "defect is fixed and its allowlist row is now a lie. Delete the row (and close its " <>
             "tracker). This red IS the bookkeeping the equality exists to force."
  end

  # ---------------------------------------------------------------------------
  # ARM 2 — TYPE COMPATIBILITY. A key-name census cannot see a type change.
  # ---------------------------------------------------------------------------

  describe "ARM 2 — a received key's emitted JSON type fits the Go field's type" do
    test "provision / resurrect / support: every received key type-checks" do
      src = go_sources()

      for {claim, body} <- [
            {"provision", provision_claim_body!()},
            {"resurrect", resurrect_claim_body!()},
            {"support", support_claim_body!()}
          ] do
        types = field_types(src, claim)

        mismatches =
          for {key, value} <- body,
              go_type = types[key],
              go_type != nil,
              not type_compatible?(value, go_type),
              do: "#{key}: emitted #{json_kind(value)} vs Go #{go_type}"

        assert mismatches == [],
               "the #{claim} claim emits a value whose JSON type cannot decode into the worker's " <>
                 "declared field type — `json.Unmarshal` fails the WHOLE payload on a type " <>
                 "mismatch, so this is a claim that dies, not a key that drops: " <>
                 inspect(mismatches)
      end
    end
  end

  # `null` decodes into anything (region/server_type are nil-honest by design).
  defp type_compatible?(nil, _go_type), do: true
  defp type_compatible?(v, go_type) when is_binary(v), do: go_type in ["string", "*string"]
  defp type_compatible?(v, go_type) when is_boolean(v), do: go_type in ["bool", "*bool"]

  defp type_compatible?(v, go_type) when is_integer(v) or is_float(v),
    do: String.contains?(go_type, "int") or String.contains?(go_type, "float")

  defp type_compatible?(v, go_type) when is_list(v), do: String.starts_with?(go_type, "[]")

  defp type_compatible?(v, go_type) when is_map(v) do
    String.starts_with?(go_type, "map[") or
      (go_type |> String.trim_leading("*") |> String.starts_with?(["A", "B", "C", "D", "E"]) and
         not String.contains?(go_type, "[")) or
      String.match?(go_type, ~r/^\*?[A-Za-z][A-Za-z0-9_]*$/)
  end

  defp json_kind(v) when is_binary(v), do: "string"
  defp json_kind(v) when is_boolean(v), do: "bool"
  defp json_kind(v) when is_integer(v), do: "int"
  defp json_kind(v) when is_float(v), do: "float"
  defp json_kind(v) when is_list(v), do: "array"
  defp json_kind(v) when is_map(v), do: "object"
  defp json_kind(nil), do: "null"

  # ---------------------------------------------------------------------------
  # ARM 3 — PER-DECODE-SITE, proven not to be a union and not to be per-struct.
  # ---------------------------------------------------------------------------

  describe "ARM 3 — the axis is the decode SITE, not the package and not a type name" do
    test "the support claim's per-site set EXCLUDES the four keys a package union would include" do
      src = go_sources()
      support = received(src, "support")

      for key <- ~w(template agent_token kind credentials) do
        refute MapSet.member?(support, key),
               "#{key} is reachable from the SUPPORT claim's decode sites — either the worker " <>
                 "grew the field (delete its @known_open row) or this arm has silently become a " <>
                 "package-wide UNION, which reports the support claim CLEAN on four keys its " <>
                 "decoder cannot see"
      end

      # …and the SAME four keys ARE in the package's union, which is precisely why
      # a union arm would false-green here. This is the rival, measured in-suite.
      union =
        src
        |> Map.values()
        |> Enum.join("\n")
        |> then(&Regex.scan(~r/json:"([^"]*)"/, &1, capture: :all_but_first))
        |> Enum.map(fn [t] -> t |> String.split(",") |> List.first() end)
        |> MapSet.new()

      for key <- ~w(template agent_token kind credentials) do
        assert MapSet.member?(union, key),
               "#{key} left internal/provisioner entirely — this arm's refutation of the UNION " <>
                 "rival is no longer measuring anything"
      end
    end

    test "the INLINE ANONYMOUS dialect struct is visible, and a per-struct-only scan would miss it" do
      src = go_sources()
      dialect = MapSet.new(site_keys(src, "support-dialect"))

      assert MapSet.equal?(
               dialect,
               MapSet.new(~w(job_id claim_token name slug region server_type))
             ),
             "the tolerated-dialect fallback at worker.go:1622 rescues a DIFFERENT key set than " <>
               "pinned: #{inspect(Enum.sort(MapSet.to_list(dialect)))}"

      # SupportJobSpec alone declares NONE of them — so a per-struct-only Side B
      # would report all six as discarded. That false-red is the second rival.
      named = MapSet.new(site_keys(src, "support"))

      assert MapSet.disjoint?(named, dialect),
             "SupportJobSpec now declares a flat key too — the per-struct false-red this arm " <>
               "exists to avoid may no longer exist, and the site list needs re-reading"
    end
  end

  # ---------------------------------------------------------------------------
  # ARM 4 — THE SITES ARE PINNED. A moved decode site reds, it does not drift.
  # ---------------------------------------------------------------------------

  describe "ARM 4 — every declared decode site is a live json.Unmarshal inside its pinned function" do
    test "each site's json.Unmarshal lives in the function it is attributed to" do
      src = go_sources()

      for s <- @sites do
        source = Map.fetch!(src, s.file)

        span =
          Go.func_span(source, s.func) ||
            flunk(
              "decode site #{s.id} (#{s.note}): its enclosing function is gone from #{s.file} — " <>
                "renamed, moved or deleted. Re-pin it: `#{s.func}`"
            )

        {first, last} = span
        inside = for n <- Go.unmarshal_lines(source, s.var), n >= first and n <= last, do: n

        assert length(inside) == 1,
               "decode site #{s.id} (#{s.note}) declares ONE `json.Unmarshal(…, &#{s.var})` " <>
                 "inside #{s.file}:#{first}-#{last}, found #{inspect(inside)}. The site MOVED " <>
                 "or forked: \"discarded AT THIS SITE\" must keep meaning a place in the worker, " <>
                 "never a vague \"unknown somewhere\"."

        assert s.line >= first and s.line <= last,
               "decode site #{s.id}'s documented line #{s.file}:#{s.line} is outside its " <>
                 "enclosing function (#{first}-#{last}); the call is now at " <>
                 "#{s.file}:#{hd(inside)}. Update the row's line — the @known_open rows quote it."
      end
    end

    test "ANTI-VACUITY: the seven decode sites are still unguarded by DisallowUnknownFields" do
      src = go_sources()
      all = src |> Map.values() |> Enum.flat_map(&Go.all_unmarshal_lines/1)

      assert length(all) >= 6,
             "only #{length(all)} json.Unmarshal call sites found in internal/provisioner — the " <>
               "Side-B scanner is broken, not the package clean"

      guarded =
        src
        |> Map.values()
        |> Enum.join("\n")
        |> String.contains?("DisallowUnknownFields")

      refute guarded,
             "internal/provisioner now uses DisallowUnknownFields somewhere. That is GOOD NEWS " <>
               "and it changes this manifest's premise: a discarded key would now be a decode " <>
               "ERROR rather than silence. Re-read the sites before trusting this file again."
    end
  end

  # ---------------------------------------------------------------------------
  # ARM 5 — @reserved's four conjuncts, and THE CUSTODY TYPE GATE.
  # ---------------------------------------------------------------------------

  describe "ARM 5 — the custody type gate" do
    test "the ineligible list is pinned by its own equality assertion" do
      assert MapSet.new(@custody_ineligible) == MapSet.new(["env", "agent_token", "credentials"]),
             "the CUSTODY TYPE GATE list changed. env, agent_token and credentials are " <>
               "USER-SUPPLIED SECRETS handed to the plane on a promise; each must be CONSUMED " <>
               "or REMOVED, never blessed as \"shipped ahead of the worker\". Shrinking this " <>
               "list is the diff that lets the crown recur — it must be argued in review, not " <>
               "slipped into the commit that adds the row it unblocks."
    end

    test "a reserved row naming a custody key is REFUSED — proven against each of the three" do
      for key <- @custody_ineligible do
        row = %{claim: "provision", key: key, site: "provision", comment_pin: "x", tracker: "t"}

        assert custody_violations([row]) == [
                 "#{key} on the provision claim: a USER-SUPPLIED SECRET may never be reserved"
               ],
               "the custody type gate did not refuse a reserved row for #{key} — without this " <>
                 "refusal the next env-shaped key gets a reserved row with all four conjuncts " <>
                 "GREEN and the exposure recurs behind an honest-looking guard"
      end
    end

    test "the committed @reserved list carries NO custody key" do
      violations = custody_violations(@reserved)

      assert violations == [],
             "THE CUSTODY TYPE GATE REFUSES THIS RESERVATION: #{Enum.join(violations, "; ")}. " <>
               "A user handed the plane a secret because a screen said it would be delivered — " <>
               "reserving it blesses an exposure the promise INDUCED. Consume the key or stop " <>
               "emitting it; \"the worker will support it later\" is not an option for a " <>
               "credential already in flight."
    end
  end

  defp custody_violations(rows) do
    for row <- rows,
        row.key in @custody_ineligible,
        do: "#{row.key} on the #{row.claim} claim: a USER-SUPPLIED SECRET may never be reserved"
  end

  describe "ARM 5 — @reserved's four mechanical conjuncts" do
    test "R1: every reserved row names a declared decode site and a genuinely discarded key" do
      src = go_sources()

      for row <- @reserved do
        sites = Map.fetch!(@claim_sites, row.claim)

        assert row.site in sites,
               "reserved row #{row.claim}/#{row.key} names site #{row.site}, which does not " <>
                 "decode that claim (#{inspect(sites)}). \"Reserved\" must mean provably " <>
                 "discarded AT A SITE, never merely \"unknown\"."

        refute MapSet.member?(MapSet.new(site_keys(src, row.site)), row.key),
               "reserved row #{row.claim}/#{row.key}: the worker DOES declare that field at " <>
                 "#{row.site}. Delete the row."
      end
    end

    test "R2: the console's claim-key vocabulary is read BY RUNNING app.js, and reds fail closed" do
      # The positive controls run on EVERY tree, reserved rows or not: node is on
      # PATH, the shipped bundle evaluates in the sandbox, exit status is 0, and
      # the hook extraction is NON-EMPTY. A conjunct whose harness only runs when
      # the list is non-empty is a conjunct nobody has ever seen work.
      hooks = console_hooks!()

      assert map_size(hooks) > 0,
             "app.js exported NOTHING on __bpTestHook — the console half of R2 is unreadable, " <>
               "and an unreadable promise-surface must never read as \"the console promises " <>
               "nothing\""

      for row <- @reserved do
        vocabulary = Map.get(hooks, "claimKeyVocabulary")

        assert is_list(vocabulary) and vocabulary != [],
               "reserved row #{row.claim}/#{row.key} cannot be blessed: app.js exports no " <>
                 "non-empty `claimKeyVocabulary` on __bpTestHook, so \"nothing tells a user " <>
                 "this key arrived\" is UNPROVEN. FAIL-CLOSED on purpose — a denial regex over " <>
                 "app.js was tried and matched two unrelated webhook-delivery lines, which is a " <>
                 "free false-positive exit for a future author. Export the vocabulary or do not " <>
                 "reserve the key."

        refute row.key in vocabulary,
               "reserved row #{row.claim}/#{row.key}: the console DOES name this key to a user " <>
                 "(#{inspect(vocabulary)}). A key a screen promises is not reserved — it is " <>
                 "broken."
      end
    end

    test "R3: every reserved row pins its emitting server comment byte-exactly" do
      router = File.read!(@router)

      for row <- @reserved do
        occurrences = router |> String.split(row.comment_pin) |> length() |> Kernel.-(1)

        assert occurrences == 1,
               "reserved row #{row.claim}/#{row.key}: its pinned server comment appears " <>
                 "#{occurrences} time(s) in router.ex, not once. Re-arming the promise in new " <>
                 "words must RED this row, which is only true while the pin is byte-exact and " <>
                 "unique."
      end
    end

    test "R4: the reserved set is disjoint from @known_open — a key is a defect OR a reservation" do
      reserved = MapSet.new(@reserved, &{&1.claim, &1.key})
      open = MapSet.new(@known_open ++ @resurrect_known_open, &{&1.claim, &1.key})

      assert MapSet.disjoint?(reserved, open),
             "a key is EITHER a tracked defect OR a deliberate reservation, never both: " <>
               inspect(MapSet.to_list(MapSet.intersection(reserved, open)))
    end
  end

  # The `node:vm` idiom of transport_manifest_test.exs:279-345 — the shipped
  # bundle is EVALUATED, never grepped, and the values come off the same
  # `__bpTestHook` the console's own JS suite reads.
  @dump_js ~S"""
  const vm = require("node:vm");
  const fs = require("node:fs");

  const noop = () => {};
  const inertEl = {
    addEventListener: noop, removeEventListener: noop, setAttribute: noop,
    removeAttribute: noop,
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    style: {}, hidden: false, value: "", innerHTML: "", textContent: "",
    querySelector: () => null, querySelectorAll: () => [],
  };
  const storage = { getItem: () => null, setItem: noop, removeItem: noop };
  const hooks = {};
  const sandbox = {
    __bpTestHook(h) { Object.assign(hooks, h); },
    document: {
      readyState: "loading",
      addEventListener: noop, removeEventListener: noop,
      querySelector: () => null, querySelectorAll: () => [],
      getElementById: () => null, createElement: () => ({ ...inertEl }),
      documentElement: { ...inertEl, getAttribute: () => null },
      body: { ...inertEl, appendChild: noop },
    },
    window: {
      addEventListener: noop, removeEventListener: noop, open: () => null,
      matchMedia: () => ({ matches: false, addEventListener: noop }),
    },
    location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
    localStorage: storage,
    sessionStorage: storage,
    navigator: {},
    URL: URL,
    URLSearchParams: URLSearchParams,
    fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
    EventSource: function () { return { addEventListener: noop, close: noop }; },
    setTimeout: noop, clearTimeout: noop, setInterval: () => 1, clearInterval: noop,
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);

  const names = Object.keys(hooks);
  if (names.length === 0) {
    console.error("app.js exported NOTHING on __bpTestHook — the console is unreadable by running, and an unreadable console must never read as 'the console promises nothing'");
    process.exit(2);
  }
  const out = {};
  for (const n of names) out[n] = true;
  if (Object.prototype.hasOwnProperty.call(hooks, "claimKeyVocabulary")) {
    out.claimKeyVocabulary = Array.from(hooks.claimKeyVocabulary || []);
  }
  process.stdout.write(JSON.stringify(out));
  """

  defp console_hooks! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip (cloud.yml installs node with
    # actions/setup-node@v4 rather than betting on the image).
    assert node, "node is not on PATH — the console half of R2 cannot be read"
    assert File.exists?(@app_js), "the shipped console bundle is missing at #{@app_js}"

    {out, status} = System.cmd(node, ["-e", @dump_js, @app_js], stderr_to_stdout: true)

    assert status == 0,
           "reading the console's exports failed (exit #{status}) — app.js could not be read BY " <>
             "RUNNING it: #{out}"

    Jason.decode!(out)
  end

  # ---------------------------------------------------------------------------
  # ARM 6 — THE WIRING ITSELF CAN LOSE.
  # ---------------------------------------------------------------------------

  describe "ARM 6 — the dispatcher actually dispatches on the Go half of this contract" do
    test "the escape ratchet's census CONTAINS internal/provisioner" do
      census = escape_check!(["--list-escapes"])

      assert String.contains?(census, "internal/provisioner"),
             "scripts/cloud-path-escape-check.sh does NOT see this file's Go root. That is the " <>
               "half-wired-and-green trap: the ratchet greps `\"\\.\\./[^\"]*\"` LITERALS, so " <>
               "writing the same directory as Path.join([__DIR__, \"..\", …]) resolves " <>
               "identically, leaves the census unchanged, exits 0 — and cloud.yml's dispatcher " <>
               "then returns false for internal/provisioner/**, so this manifest NEVER RUNS on " <>
               "the PR class that adds a discarded claim key, while Cloud gate reports success. " <>
               "The Go root MUST stay a single string literal.\ncensus:\n#{census}"
    end

    test "internal/provisioner/** is DECLARED in CLOUD_PATHS" do
      set = escape_check!(["--print-set", "cloud"])

      assert set |> String.split("\n") |> Enum.member?("internal/provisioner/**"),
             "internal/provisioner/** is not in CLOUD_PATHS, so a Go-only edit to worker.go " <>
               "would skip the only gate that checks it:\n#{set}"
    end

    test "the dispatcher answers TRUE for a worker.go-only change" do
      assert String.trim(escape_check!(["--match", "cloud"], "internal/provisioner/worker.go\n")) ==
               "true"
    end

    test "the Go root's attribution line is byte-exactly the SINGLE-STRING-LITERAL form" do
      # The census arm above is necessary and NOT sufficient: a quoted `..`-path
      # anywhere in this file — a docstring sentence, a comment, an error message
      # — satisfies the ratchet's grep while the REAL read is a segment list.
      # Measured: with the literal moved into the moduledoc as prose and
      # `@provisioner` rewritten as `Path.expand(Path.join([__DIR__, …]))`, the
      # ratchet printed "OK: every repo-root read … is dispatched on", exited 0,
      # and the census still listed internal/provisioner — a fully half-wired
      # guard under a green gate. So the FORM of the read itself is pinned.
      # The ATTRIBUTION LINE is isolated first and asserted on alone. Searching
      # the whole file would be self-satisfying — the needle would match its own
      # source — which is the same shape of vacuous pass this arm exists to kill.
      attribution =
        __ENV__.file
        |> File.read!()
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(String.trim_leading(&1), "@provisioner "))

      assert attribution != nil, "the @provisioner attribution line is gone"

      assert String.contains?(attribution, "Path.expand(" <> <<?">>) and
               String.ends_with?(@provisioner, "internal/provisioner"),
             "this file's Go root is no longer the single-string-literal form. " <>
               "`Path.join([__DIR__, \"..\", …])` resolves to the IDENTICAL directory and is " <>
               "invisible to scripts/cloud-path-escape-check.sh, so cloud.yml's dispatcher would " <>
               "return false for internal/provisioner/** and this manifest would never run on " <>
               "the PR class that adds a discarded claim key — while Cloud gate reports success."
    end

    test "the Go root resolves to a real directory holding the worker" do
      assert File.dir?(@provisioner)
      assert File.exists?(Path.join(@provisioner, "worker.go"))
    end
  end

  # `bash`, not `sh`: the ratchet uses here-strings, which dash does not have, and
  # a guard that silently degrades on the CI image is not a guard. stdin is piped
  # in and CLOSED — `--match` reads until EOF, so an unclosed stdin would hang the
  # suite on the very case (no match) the assertion exists to distinguish.
  defp escape_check!(args, stdin \\ "") do
    bash = System.find_executable("bash")
    assert bash, "bash is not on PATH — the escape ratchet cannot be run"

    script = Enum.map_join([@escape_check | args], " ", &("'" <> &1 <> "'"))
    piped = "printf '%s' " <> inspect(stdin) <> " | " <> script

    {out, status} =
      System.cmd(bash, ["-c", piped], cd: @repo_root, stderr_to_stdout: true)

    assert status == 0, "cloud-path-escape-check exited #{status}:\n#{out}"
    out
  end

  # ---------------------------------------------------------------------------
  # ANTI-VACUITY — Side A really reached the optional keys.
  # ---------------------------------------------------------------------------

  describe "ANTI-VACUITY — the fixtures exercise the keys most likely to drift" do
    test "the provision claim carries kind + credentials + a NON-EMPTY env + template" do
      body = provision_claim_body!()

      assert body["kind"] == "azure"
      assert body["credentials"] == @azure_creds
      assert body["env"] == %{"FOO" => "bar"}
      assert body["template"] == "blog"

      # A LIVE token: minted and hash-persisted at claim time, and the provision
      # worker HAS a field for it (provisioner.JobSpec.AgentToken → the configure
      # step's /etc/barkpark/agent.token). This assertion used to live on the
      # SUPPORT arm below, where it proved the opposite — a real credential
      # recorded for a box with no install path.
      assert is_binary(body["agent_token"]) and body["agent_token"] != ""
      assert %Barkpark{} = Registry.verify_agent_token(body["agent_token"])
    end

    test "the resurrect claim carries bundle_ref on top of the full provision claim" do
      body = resurrect_claim_body!()

      assert is_binary(body["bundle_ref"]) and body["bundle_ref"] != ""
      assert body["kind"] == "azure"
      assert body["env"] == %{"FOO" => "bar"}
    end

    test "the support claim carries the nested support map AND the four discarded keys" do
      body = support_claim_body!()

      assert is_map(body["support"])
      assert body["support"]["dataset"] == "production"

      for key <- ~w(env template kind credentials) do
        assert Map.has_key?(body, key),
               "the support claim no longer emits #{key} — the @known_open row for it is " <>
                 "measuring nothing, and this arm has gone vacuous on the key that matters most"
      end

      # THE SHARPEST ROW OF ALL, NOW INVERTED (cch-w53-bl-…-a-live-agent-token).
      # This arm used to assert a LIVE agent token here and verify it back to a
      # %Barkpark{} — which was the proof the plane held a real credential for a
      # box with NO install path (`SupportJobSpec` declares no `agent_token`
      # field; `claimSupport`'s tolerated dialect rescues six other flat keys).
      # `support_provision_claim_json/2` no longer mints, so the key must be
      # ABSENT. The ledger half — that no `agent_tokens` row is written for the
      # support row either — is pinned in `fleet_supports_test.exs`, which has
      # the barkpark id this body deliberately does not carry.
      refute Map.has_key?(body, "agent_token"),
             "the support claim ships an agent token again. If the Go worker grew the field, " <>
               "re-add the mint AND a receipt test together; if it did not, this is the custody " <>
               "defect recurring — a credential recorded as handed over and never delivered."
    end
  end

  # ---------------------------------------------------------------------------
  # THE LEDGER — every allowlist row names a tracker and a site.
  # ---------------------------------------------------------------------------

  describe "the allowlists are bookkeeping, not a junk drawer" do
    test "@known_open holds exactly five rows, each naming its decode site and bp task" do
      assert length(@known_open) == 5

      assert MapSet.new(@known_open, &{&1.claim, &1.key}) ==
               MapSet.new([
                 {"provision", "env"},
                 {"support", "env"},
                 {"support", "template"},
                 {"support", "kind"},
                 {"support", "credentials"}
               ]),
             "the ruled @known_open set changed. Adding a row here is admitting a NEW silently " <>
               "discarded key; deleting one is claiming a defect is fixed. Both are review-worthy."

      for row <- @known_open ++ @resurrect_known_open do
        assert String.contains?(row.site, "internal/provisioner/worker.go:")
        assert String.starts_with?(row.tracker, "cch-")
      end
    end
  end
end
