defmodule BarkparkWeb.Contract.RateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)

    original = Application.get_env(:barkpark, :rate_limits)

    # Small capacity ON PURPOSE: capacity == read_per_minute and refill ==
    # read_per_minute/60 tokens/sec, so a 200-request burst on a LOADED CI
    # runner takes long enough to refill ≥1 token and request 201 sails
    # through as 404 (seen live on 683301e's run — the suite grew and the
    # runner slowed; locally the burst takes 90ms and always passed). A
    # 10-burst finishes in ~5ms ≈ 0.001 refilled tokens: deterministic.
    Application.put_env(
      :barkpark,
      :rate_limits,
      read_per_minute: 10,
      write_per_minute: 60,
      datasets: %{}
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  test "a burst past capacity hits the 429 on request capacity+1", %{conn: _conn} do
    base_conn = Phoenix.ConnTest.build_conn()

    for _ <- 1..10 do
      resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
      refute resp.status == 429
    end

    resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
    assert resp.status == 429
    # retry-after = time to refill one token = ceil(60 / read_per_minute).
    assert get_resp_header(resp, "retry-after") == ["6"]
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "rate_limited"
  end

  # ── THE HINT'S REMEDY MUST BE REACHABLE AT EVERY EMITTER OF THE CODE ───────
  #
  # task-57081836b628df35 c0/c3. `Content.Errors.put_hint/1` dispatches on the
  # CODE STRING ALONE — no module, no conn, no route — so the one `@hints`
  # entry for "rate_limited" is served at EVERY emitter of that code:
  #
  #   "Back off and retry after the Retry-After header's value; reduce request
  #    rate."
  #
  # That sentence names a RESPONSE FIELD. A 429 that carries the hint and not
  # the header is the defect the task governs: the refusal is honest about the
  # NO and sends the caller to read a value off something that is not there.
  # The arms below are the emitter families, each asserted BY NAME so a
  # regression says WHICH refusal lost its remedy rather than "a header was
  # missing somewhere".
  #
  # NOT A PARALLEL CHECKER: this is the file that already owned the
  # header-carries-the-wait assertion for the read-limiter plug (above). The
  # two revoke/form families are added here rather than in a new module so one
  # place fails when the invariant does.
  describe "every rate_limited refusal carries the Retry-After its own hint names" do
    test "the app-token revoke gate (DELETE /v1/auth/app-tokens)" do
      admin = "w6r15-revoke-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Barkpark.Auth.create_token(admin, "w6r15-revoke-admin", "production", [
          "read",
          "write",
          "admin"
        ])

      body = %{"email" => "w6r15-nobody@example.test"}

      burst =
        for _ <- 1..11 do
          Phoenix.ConnTest.build_conn()
          |> put_req_header("authorization", "Bearer #{admin}")
          |> put_req_header("content-type", "application/json")
          |> delete("/v1/auth/app-tokens", body)
        end

      throttled = List.last(burst)

      assert throttled.status == 429,
             "DELETE /v1/auth/app-tokens: the 11th call past a capacity-10 bucket was not braked (got #{throttled.status}) — this arm proves nothing until it refuses"

      assert_hinted_retry_after!(throttled, "DELETE /v1/auth/app-tokens")
    end

    test "the anonymous Bulldocs form gate (POST .../form-responses)" do
      {workspace, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      slug = "w6r15-form-#{System.unique_integer([:positive])}"

      {:ok, _paper} =
        Barkpark.Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            blocks: [
              %{
                "id" => "grill",
                "type" => "form",
                "questions" => [
                  %{"id" => "q-fit", "prompt" => "Does it fit?", "type" => "yesno"}
                ]
              }
            ],
            workspace_id: workspace.id,
            project_id: project.id
          })
        )

      path = "/v1/plugins/bulldocs/papers/#{slug}/form-responses"

      burst =
        for _ <- 1..21 do
          Phoenix.ConnTest.build_conn()
          |> put_req_header("content-type", "application/json")
          |> post(path, %{"answers" => %{"q-fit" => "yes"}})
        end

      throttled = List.last(burst)

      assert throttled.status == 429,
             "POST #{path}: the 21st submission past a capacity-20 bucket was not braked (got #{throttled.status}) — this arm proves nothing until it refuses"

      assert_hinted_retry_after!(
        throttled,
        "POST /v1/plugins/bulldocs/papers/:slug/form-responses"
      )
    end
  end

  # The assertion both arms share. It reads the HINT off the response and only
  # then demands the header, so it is conditional on the promise actually being
  # made rather than tautological: an envelope that stopped naming the header
  # would be the OTHER admissible fix (STOP naming it) and is not failed here.
  defp assert_hinted_retry_after!(resp, label) do
    body = Jason.decode!(resp.resp_body)
    error = body["error"] || %{}

    assert error["code"] == "rate_limited",
           "#{label}: expected a rate_limited envelope, got #{inspect(error["code"])}"

    hint = error["hint"] || ""

    assert hint =~ "Retry-After",
           "#{label}: the rate_limited hint no longer names the Retry-After header (#{inspect(hint)}) — if that is deliberate, delete this arm; if not, the remedy sentence regressed"

    assert get_resp_header(resp, "retry-after") != [],
           "#{label}: the refusal's hint says \"retry after the Retry-After header's value\" and the response carries NO retry-after header — the remedy it names cannot be taken"

    [value] = get_resp_header(resp, "retry-after")

    assert {seconds, ""} = Integer.parse(value),
           "#{label}: retry-after is #{inspect(value)}, which is not the integer seconds the hint tells the caller to wait"

    assert seconds > 0,
           "#{label}: retry-after is #{seconds} — a non-positive wait is not a remedy"

    assert error["details"]["retry_after"] == seconds,
           "#{label}: details.retry_after (#{inspect(error["details"]["retry_after"])}) disagrees with the retry-after header (#{seconds}); two numbers for one wait means one of them is wrong"
  end
end
