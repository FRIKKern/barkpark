defmodule BarkparkCloud.RawFailureChannelOracleTest do
  @moduledoc """
  task-4f363dc65ac43203 — THE WHOLE-PAYLOAD ORACLE FOR THE RAW FAILURE COLUMNS.

  Wave 13 S2 shipped `FailureCopy.scrub/1` at SEVEN display boundaries, SITE BY
  SITE. The seventh (`stages[].detail`) was found only by driving the payload,
  because `Sites.Deploy.stages/1` re-derives its fold from the RAW `d.console`
  instead of from `deployment_json/1`'s already-scrubbed copy. That is the shape
  of the residual risk this file exists for: an EIGHTH channel — a new serializer
  field, a new notification reader, a new fold that re-derives from a raw column
  — ships unscrubbed and nothing reds.

  ## What is guarded

  1. **The column set is DERIVED, not listed.** `@columns` below is cross-checked
     against `ProvisionJob.__schema__/1` and `Deployment.__schema__/1` by a
     predicate (`{:array, :map}` fields, plus `:error` / `:failure_reason` /
     `:detail` strings). Add a new raw failure-bearing column to either schema
     and `"the guarded column set is exactly what the schemas expose"` reds until
     it is written into the corpus here.

  2. **A distinct sentinel per column.** Each raw column is written a DIFFERENT
     24-char secret, so a leak names the column that leaked instead of "something
     leaked".

  3. **The refute is WHOLE-PAYLOAD.** Every channel is asserted against the
     ENCODED response body / email body, not against one field. A field nobody
     thought to name is covered by construction.

  4. **A CARRIER CENSUS, because a payload-wide refute is not automatically a
     structural guard.** S2's own first whole-payload assertion was VACUOUSLY
     GREEN: its fixture used a lowercase stage name, `stages/1` filters
     `&(&1["stage"] in @stages)` (uppercase), so the bytes never reached the
     boundary the refute was aimed at. Every capture here therefore carries a
     unique NON-SECRET marker, and each channel asserts the exact MULTISET of
     markers it rendered. A channel that silently stops carrying a column reds;
     so does a NEW fold that starts re-deriving from one.

  ## Fixture shape is load-bearing (charter D387)

  Each secret is NON-PREFIXED, sub-32-char, mixed-case alnum, spelled behind an
  `api_key=` key whose lookbehind is blocked by a CSI run immediately to its
  LEFT. A provider-prefixed token (`sk-…`), a 32+ char one, or an escape in the
  VALUE position all close under a bare `scrub/1` too — i.e. would be green over
  a live hole. See `scrub_boundary_http_test.exs` for the measurement.

  ## MUTATION PROOF

  Delete any ONE of the display-boundary scrubs and this file reds:

    * `lib/barkpark_cloud/sites/deploy.ex:141` (`stage_caption/2`'s non-failed
      arm, `strip_ansi |> scrub`)
    * `lib/barkpark_cloud/web/router.ex:11752` (`class_then_capture/1`)
    * `lib/barkpark_cloud/notifications/event_email.ex:345`
      (`cause_then_capture/1`)
    * `lib/barkpark_cloud/failure_copy.ex:548` (`raw/1`)
    * `lib/barkpark_cloud/failure_copy.ex:606` (`humanize/1`)

  The pasted REDs live in the PR body for task-4f363dc65ac43203.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Sites}
  alias BarkparkCloud.Notifications.{EmailSettings, EventEmail}
  alias BarkparkCloud.Registry.{Deployment, ProvisionJob}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # ---------------------------------------------------------------------------
  # THE GUARDED COLUMN SET — one sentinel each.
  #
  # `{schema, column, shape, tag, secret}`. `shape` is `:scalar` or
  # `{:list, member_key}`. The secrets differ so a leak is self-identifying.
  # ---------------------------------------------------------------------------
  @columns [
    {ProvisionJob, :error, :scalar, "pj-error", "Qp9vR4tZ7wN1cB6yH3sD5fG0"},
    {ProvisionJob, :steps, {:list, "detail"}, "pj-steps", "Kd2mXe8rJb5tYw3qLn7vZc1a"},
    {ProvisionJob, :console, {:list, "line"}, "pj-console", "Vt6hBn4sQz9wMr2kEy8pAd5c"},
    {Deployment, :failure_reason, :scalar, "dep-reason", "Zf3jUq7bWx1nRc5gTm9dHv4s"},
    {Deployment, :detail, :scalar, "dep-detail", "Ln8cPw2yGk6vSb4tXr1mDq7z"},
    {Deployment, :console, {:list, "line"}, "dep-console", "Hs5rTz1xNc9bJw4vFm7kQd3p"}
  ]

  # The derivation predicate. A column is raw-failure-bearing when it is a
  # `{:array, :map}` narration column (steps / console) or one of the three
  # scalar capture columns. Keep this a RULE, never a hand-kept list — an
  # enumeration is a snapshot.
  defp raw_failure_columns(schema) do
    for f <- schema.__schema__(:fields),
        t = schema.__schema__(:type, f),
        t == {:array, :map} or (t == :string and f in [:error, :failure_reason, :detail]),
        do: f
  end

  # A capture as the worker stores it: colourised, key-shaped, and carrying a
  # marker that is NOT secret so a channel can prove it actually rendered it.
  defp capture(tag, secret), do: "\e[31mapi_key=#{secret}\e[0m oracle carrier #{tag}"

  defp marker(tag), do: "oracle carrier #{tag}"

  defp all_secrets, do: for({_, _, _, _, s} <- @columns, do: s)

  # ---------------------------------------------------------------------------
  # The two obligations every channel owes.
  # ---------------------------------------------------------------------------

  # THE ORACLE. `rendered` is the WHOLE encoded body — never one field.
  defp refute_every_sentinel!(rendered, where) do
    for {_, col, _, tag, secret} <- @columns do
      refute rendered =~ secret,
             "#{where} leaked the sentinel written to #{col} (tag #{tag}).\n" <>
               "The whole rendered payload was:\n#{rendered}"
    end
  end

  # dr-bl-w8 — THE SECOND AXIS: NO TERMINAL ESCAPE BYTES ON THE WIRE.
  #
  # The sentinel refute above catches a boundary that never scrubs. It does NOT
  # catch a boundary that scrubs WITHOUT stripping: `scrub/1` alone redacts the
  # value and leaves the CSI/OSC runs sitting in the payload, so the field is
  # secret-free and still carries raw terminal control bytes. That is a real
  # residual channel — an escape run is a container (an OSC title string can
  # hold arbitrary text between `\e]` and BEL), so bytes that never passed a
  # scrub's key clause ride to the reader inside it, and every SPA renderer we
  # have HTML-escapes rather than strips, so it renders as literal garbage.
  #
  # Every display boundary on main is `FailureCopy.raw/1` (`strip_ansi |>
  # scrub`) or `humanize/1` (`classify |> strip_ansi |> scrub`), so a correct
  # payload carries ZERO 0x1B. A NEW raw-failure field piped through a bare
  # `scrub/1` — or through no fold at all — reds here even when its value
  # happens to hold nothing secret-shaped.
  #
  # BOTH forms are checked: the raw byte (an email text_body is not JSON) and
  # `\u001b`, which is how Jason encodes 0x1B inside a JSON string.
  defp refute_escape_bytes!(rendered, where) do
    refute rendered =~ "\e",
           "#{where} shipped a raw 0x1B terminal escape byte.\n" <>
             "A raw-failure field reached the wire without `FailureCopy.strip_ansi/1`.\n" <>
             "The whole rendered payload was:\n#{inspect(rendered)}"

    refute rendered =~ "\\u001b" or rendered =~ "\\u001B",
           "#{where} shipped a JSON-encoded \\u001b terminal escape.\n" <>
             "A raw-failure field reached the wire without `FailureCopy.strip_ansi/1`.\n" <>
             "The whole rendered payload was:\n#{inspect(rendered)}"
  end

  # THE FIXTURE ASSERTION (positive control). Which columns' bytes actually
  # REACHED this channel, and how many times. A vacuous fixture — one filtered
  # out upstream, as S2's lowercase stage name was — shows up here as a missing
  # tag, so this file cannot go green by never driving the boundary.
  defp carrier_census(rendered) do
    for {_, _, _, tag, _} <- @columns,
        n = length(String.split(rendered, marker(tag))) - 1,
        n > 0,
        into: %{},
        do: {tag, n}
  end

  defp assert_channel!(rendered, where, expected_census) do
    refute_every_sentinel!(rendered, where)
    refute_escape_bytes!(rendered, where)

    assert carrier_census(rendered) == expected_census, """
    #{where}: the CARRIER CENSUS moved.

    expected: #{inspect(expected_census)}
    actual:   #{inspect(carrier_census(rendered))}

    A tag that DISAPPEARED means this channel stopped rendering that raw column —
    or the fixture is being filtered out upstream and the refute above is now
    VACUOUS (the wave-13 S2 lowercase-stage trap). A tag that APPEARED or grew
    means a NEW fold re-derives from a raw column: prove it is scrubbed, then
    write it into the census.
    """
  end

  ## ---------------------------------------------------------------------------
  ## Fixtures
  ## ---------------------------------------------------------------------------

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(url: "https://acme-#{n}.barkpark.cloud", host: "203.0.113.10")
    |> Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read_xyz"
      })

    site
  end

  defp cap_for(tag) do
    {_, _, _, ^tag, secret} = Enum.find(@columns, fn {_, _, _, t, _} -> t == tag end)
    capture(tag, secret)
  end

  setup do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    {:ok, job} = Registry.enqueue_provision_job(bp)

    # Written through the SAME context functions the off-box Go provisioner calls,
    # so the escape bytes arrive exactly as a real capture arrives.
    job =
      job
      |> Ecto.Changeset.change(status: "failed", error: cap_for("pj-error"))
      |> Repo.update!()

    {:ok, _} = Registry.append_provision_step(job.id, "create", "failed", cap_for("pj-steps"))
    {:ok, _} = Registry.append_provision_console(job.id, cap_for("pj-console"))

    {:ok, d} = Sites.Deploy.enqueue(site, bp)

    d =
      d
      |> Ecto.Changeset.change(
        status: "failed",
        stage: "BUILD",
        failure_reason: cap_for("dep-reason"),
        detail: cap_for("dep-detail"),
        # BOTH member keys the boundaries read: `line` (deployment_json's
        # `scrub_entry`) and `detail` (deployment_json's `caption_entry` AND
        # `Sites.Deploy.stages/1`, the SEVENTH boundary, which re-derives its
        # fold from this RAW column rather than from the scrubbed serializer
        # output). An entry without `detail` leaves `stages[].detail` nil and the
        # seventh boundary undriven — a fixture that is green over a live hole.
        console: [
          # A NON-failed entry as well as a failed one, because
          # `Sites.Deploy.stage_caption/2` has TWO arms and they are two
          # different scrub carriers: `failed` -> `FailureCopy.humanize/1`
          # (classify |> scrub), anything else -> `strip_ansi |> scrub`
          # (deploy.ex:141). A corpus with only failed entries leaves the second
          # arm undriven and its deletion silent.
          %{
            "stage" => "PLAN",
            "status" => "done",
            "line" => cap_for("dep-console"),
            "detail" => cap_for("dep-console")
          },
          %{
            "stage" => "BUILD",
            "status" => "failed",
            "line" => cap_for("dep-console"),
            "detail" => cap_for("dep-console")
          }
        ]
      )
      |> Repo.update!()

    {:ok, token} = Accounts.create_user_session_token(user)
    %{bp: bp, site: site, job: job, deployment: d, token: token}
  end

  defp get_body(path, token) do
    conn =
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"
    conn.resp_body
  end

  ## ---------------------------------------------------------------------------
  ## 0. The set itself
  ## ---------------------------------------------------------------------------

  test "the guarded column set is exactly what the schemas expose" do
    declared =
      @columns |> Enum.map(fn {s, c, _, _, _} -> {s, c} end) |> MapSet.new()

    derived =
      for schema <- [ProvisionJob, Deployment],
          col <- raw_failure_columns(schema),
          into: MapSet.new(),
          do: {schema, col}

    assert declared == derived, """
    A raw failure-bearing column exists that this oracle does not drive.

    only in the schemas: #{inspect(MapSet.difference(derived, declared) |> MapSet.to_list())}
    only in @columns:    #{inspect(MapSet.difference(declared, derived) |> MapSet.to_list())}

    Write it a sentinel in @columns and extend the per-channel censuses below.
    """
  end

  test "the sentinels are distinct — a leak names its own column" do
    assert length(Enum.uniq(all_secrets())) == length(@columns)
  end

  test "the corpus really is in the DB, raw — this is a display fold, not a data rewrite",
       %{job: job, deployment: d} do
    stored_job = Repo.get(ProvisionJob, job.id)
    stored_dep = Repo.get(Deployment, d.id)

    assert stored_job.error == cap_for("pj-error")
    assert hd(stored_job.steps)["detail"] == cap_for("pj-steps")
    assert hd(stored_job.console)["line"] == cap_for("pj-console")
    assert stored_dep.failure_reason == cap_for("dep-reason")
    assert stored_dep.detail == cap_for("dep-detail")
    assert hd(stored_dep.console)["line"] == cap_for("dep-console")
  end

  ## ---------------------------------------------------------------------------
  ## 1. Serving routes — whole-payload
  ## ---------------------------------------------------------------------------

  test "GET /v1/barkparks", %{token: token} do
    assert_channel!(get_body("/v1/barkparks", token), "GET /v1/barkparks", %{
      "pj-error" => 1,
      "pj-steps" => 1,
      "pj-console" => 1
    })
  end

  test "GET /v1/sites", %{token: token} do
    # `put_last_deployment/3` embeds the HUMANIZED failure_reason (HONESTY LAW:
    # never console/build_log_url), so exactly one raw column reaches this list.
    assert_channel!(get_body("/v1/sites", token), "GET /v1/sites", %{"dep-reason" => 1})
  end

  test "GET /v1/sites/:id", %{site: site, token: token} do
    # `put_current_deployment/3` embeds a deployment only while one is ACTIVE, so
    # a settled `failed` row reaches this payload through NO raw column today.
    # The census is deliberately EMPTY rather than the route being dropped: the
    # day this route starts embedding one, the census reds and the author has to
    # prove the fold before writing it in.
    assert_channel!(get_body("/v1/sites/#{site.id}", token), "GET /v1/sites/:id", %{})
  end

  test "GET /v1/sites/:id/deployments", %{site: site, token: token} do
    assert_channel!(
      get_body("/v1/sites/#{site.id}/deployments", token),
      "GET /v1/sites/:id/deployments",
      # dep-reason 2 = `failure_reason` (humanize) + `failure_reason_raw` (raw/1).
      # dep-console 2 = `console[].line` (scrub_entry) + `console[].detail`
      # (caption_entry). dep-detail 1 = the deployment's own `detail` column.
      # 2 console entries x (line + detail) = 4 console carriers.
      %{"dep-reason" => 2, "dep-detail" => 1, "dep-console" => 4}
    )
  end

  test "GET /v1/sites/:id/deployments/:dep_id", %{site: site, deployment: d, token: token} do
    assert_channel!(
      get_body("/v1/sites/#{site.id}/deployments/#{d.id}", token),
      "GET /v1/sites/:id/deployments/:dep_id",
      # The list census PLUS a THIRD `console` carrier: `stages[].detail`, the
      # seventh boundary — `Sites.Deploy.stages/1` re-derives its fold from the
      # RAW `d.console` instead of from `deployment_json/1`'s scrubbed copy, so
      # it is its own display boundary. That 3 is what the trap test below
      # knocks back to 2.
      # The list census PLUS one `stages[].detail` per recorded stage (PLAN and
      # BUILD) = 6.
      %{"dep-reason" => 2, "dep-detail" => 1, "dep-console" => 6}
    )
  end

  ## ---------------------------------------------------------------------------
  ## 2. Email renderers — the other display boundary, driven off the SAME columns
  ## ---------------------------------------------------------------------------

  defp email_body(event, detail) do
    EventEmail.build(
      %EmailSettings{},
      event,
      %{"name" => "acme", "detail" => detail},
      "ops@example.com"
    ).text_body
  end

  test ":provision_failed email — fed from provision_jobs.error, as router.ex does",
       %{job: job} do
    detail = Repo.get(ProvisionJob, job.id).error

    assert_channel!(email_body(:provision_failed, detail), "EventEmail :provision_failed", %{
      "pj-error" => 1
    })
  end

  test ":deployment_failed email — fed from deployments.failure_reason, as registry.ex does",
       %{deployment: d} do
    detail = Repo.get(Deployment, d.id).failure_reason

    assert_channel!(email_body(:deployment_failed, detail), "EventEmail :deployment_failed", %{
      "dep-reason" => 1
    })
  end

  test ":agent_unreachable email — the detail/1 site", %{job: job} do
    detail = Repo.get(ProvisionJob, job.id).error

    assert_channel!(email_body(:agent_unreachable, detail), "EventEmail :agent_unreachable", %{
      "pj-error" => 1
    })
  end

  ## ---------------------------------------------------------------------------
  ## 3. The vacuity control — the trap that made S2's own payload-wide refute
  ##    green over a live hole.
  ## ---------------------------------------------------------------------------

  test "a lowercase stage name is filtered out of stages/1 — the census, not the refute, catches it",
       %{site: site, deployment: d, token: token} do
    # `Sites.Deploy.stages/1` filters `&(&1["stage"] in @stages)` and @stages is
    # UPPERCASE. Re-write the corpus with the trap shape.
    d
    |> Ecto.Changeset.change(
      # IDENTICAL to the setup corpus except the BUILD entry's stage-name CASE —
      # so the only variable between the green census and this one is
      # `stages/1`'s uppercase filter.
      console: [
        %{
          "stage" => "PLAN",
          "status" => "done",
          "line" => cap_for("dep-console"),
          "detail" => cap_for("dep-console")
        },
        %{
          "stage" => "build",
          "status" => "failed",
          "line" => cap_for("dep-console"),
          "detail" => cap_for("dep-console")
        }
      ]
    )
    |> Repo.update!()

    body = get_body("/v1/sites/#{site.id}/deployments/#{d.id}", token)

    # The payload-wide refute still passes — that is the whole point: it is
    # VACUOUS here for the stage channel.
    refute_every_sentinel!(body, "trap payload")

    # The census is what reds: `dep-console` falls 6 -> 5 because `stages/1`
    # dropped the BUILD entry, so the seventh boundary never saw those bytes.
    assert carrier_census(body)["dep-console"] == 5

    assert_raise ExUnit.AssertionError, fn ->
      assert_channel!(body, "trap", %{
        "dep-reason" => 2,
        "dep-detail" => 1,
        "dep-console" => 6
      })
    end
  end

  ## ---------------------------------------------------------------------------
  ## 4. dr-bl-w8 — console[].line is STRIPPED, not merely scrubbed.
  ## ---------------------------------------------------------------------------

  @doc false
  # A secret spelled INSIDE the escape sequence, not beside it. An OSC string
  # (`\e]0;…\a`) is a container: everything between `\e]` and the BEL is
  # arbitrary text, and a bare `FailureCopy.scrub/1` does not look inside it —
  # the run is not a key/value shape the scrub's clauses recognise, so under
  # `scrub` alone BOTH the escape bytes and the token they carry ride to the
  # reader in cleartext. `strip_ansi/1` deletes the whole run, so the ONLY fold
  # that closes this is a strip that runs BEFORE the scrub, i.e.
  # `FailureCopy.raw/1` — which is what `scrub_entry/2` calls.
  @osc_secret "Wj4nQx8vTb2mYc6rKp1sGz9d"

  defp osc_console_line(tag) do
    "\e]0;api_key=#{@osc_secret}\a\e[31mBUILD failed\e[0m #{marker(tag)}"
  end

  test "console[].line: a secret carried INSIDE an escape sequence reaches the wire as neither ESC bytes nor the token",
       %{site: site, deployment: d, token: token} do
    d
    |> Ecto.Changeset.change(
      console: [
        %{
          "stage" => "BUILD",
          "status" => "failed",
          "line" => osc_console_line("dep-console"),
          "detail" => osc_console_line("dep-console")
        }
      ]
    )
    |> Repo.update!()

    body = get_body("/v1/sites/#{site.id}/deployments/#{d.id}", token)

    # The DB still holds it raw — this is a display fold, not a data rewrite.
    assert Repo.get(Deployment, d.id).console |> hd() |> Map.get("line") =~ @osc_secret

    payload = Jason.decode!(body)["deployment"]
    lines = for e <- payload["console"] || [], do: e["line"]

    # POSITIVE CONTROL, first: the boundary actually rendered this line. Without
    # it every assertion below is satisfiable by an EMPTY console array, which is
    # exactly how a strip that ate the whole string would look.
    assert lines != [],
           "the deployment payload rendered NO console entries — the refutes below are vacuous"

    assert Enum.any?(lines, &(&1 =~ marker("dep-console"))),
           "console[].line lost its non-secret marker: #{inspect(lines)}"

    for line <- lines do
      refute line =~ @osc_secret,
             "console[].line shipped the token spelled inside the OSC run: #{inspect(line)}"

      refute line =~ "\e", "console[].line shipped a raw 0x1B byte: #{inspect(line)}"
    end

    # And the whole-payload form, so a SIBLING field that re-derives from the
    # same raw column is covered too.
    refute body =~ @osc_secret
    refute_escape_bytes!(body, "GET /v1/sites/:id/deployments/:dep_id (OSC corpus)")
  end
end
