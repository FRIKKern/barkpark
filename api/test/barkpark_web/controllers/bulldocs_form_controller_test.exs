defmodule BarkparkWeb.BulldocsFormControllerTest do
  @moduledoc """
  The anonymous form-submission endpoint (study play #5): paper-anchored,
  question-id allowlisted, size-capped, honeypotted. Every test posts
  anonymously — the whole point of the `:public_api` bucket.
  """
  # sync: resets Barkpark.RateLimiter; :barkpark_rate_limiter is a :named_table — whole-node state
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  # Every submission is billed to an IP-keyed bucket (`{:bulldocs_form, ip}`,
  # capacity 20, refill 1/min) in the WHOLE-NODE :barkpark_rate_limiter table.
  # In tests every direct conn is 127.0.0.1, so without a per-test reset this
  # file spends ONE shared loopback budget for the entire run — the same
  # untreated shape PR #13284 fixed on token revoke — and the spam test's
  # forwarded-IP buckets stay spent across repeated runs in one BEAM.
  setup :reset_rate_limiter!

  defp path(slug), do: "/v1/plugins/bulldocs/papers/#{slug}/form-responses"

  defp seed_paper!(blocks) do
    {workspace, project} = ensure_default_scope!()
    slug = "form-paper-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: blocks,
          workspace_id: workspace.id,
          project_id: project.id
        })
      )

    slug
  end

  defp form_blocks do
    [
      %{
        "id" => "grill",
        "type" => "form",
        "questions" => [
          %{"id" => "q-fit", "prompt" => "Does it fit?", "type" => "yesno"},
          %{"id" => "q-notes", "prompt" => "Notes", "type" => "text"}
        ]
      }
    ]
  end

  defp responses_for(slug) do
    from(d in Document,
      where: d.type == "form_response",
      where: fragment("?->>'paper_slug' = ?", d.content, ^slug)
    )
    |> Repo.all()
  end

  test "happy path: stores the allowlisted answers and returns 201 with the id", %{conn: conn} do
    slug = seed_paper!(form_blocks())

    resp =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes", "q-notes" => "ship it"}})
      |> json_response(201)

    assert resp["ok"] == true
    assert is_binary(resp["id"])

    assert [doc] = responses_for(slug)
    assert doc.content["answers"] == %{"q-fit" => "Yes", "q-notes" => "ship it"}
    assert is_binary(doc.content["submitted_at"])
  end

  test "unknown answer keys are dropped; all-unknown filters to a 422", %{conn: conn} do
    slug = seed_paper!(form_blocks())

    resp =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes", "smuggled" => "x"}})
      |> json_response(201)

    assert resp["ok"] == true
    assert [doc] = responses_for(slug)
    refute Map.has_key?(doc.content["answers"], "smuggled")

    slug2 = seed_paper!(form_blocks())

    assert %{"error" => %{"code" => "validation_failed", "message" => "no valid answers" <> _}} =
             conn
             |> post(path(slug2), %{"answers" => %{"smuggled" => "x"}})
             |> json_response(422)

    assert responses_for(slug2) == []
  end

  test "a paper without a form block is a 422; an unknown slug a 404", %{conn: conn} do
    slug =
      seed_paper!([
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "hi"}]}
      ])

    assert %{"error" => %{"code" => "validation_failed", "message" => "paper has no form block"}} =
             conn |> post(path(slug), %{"answers" => %{"q" => "a"}}) |> json_response(422)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> post(path("never-published-#{System.unique_integer([:positive])}"), %{
               "answers" => %{"q" => "a"}
             })
             |> json_response(404)
  end

  test "the honeypot returns a vacuous 201 and writes nothing", %{conn: conn} do
    slug = seed_paper!(form_blocks())

    resp =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes"}, "website" => "spam.example"})
      |> json_response(201)

    assert resp["ok"] == true
    refute Map.has_key?(resp, "id")
    assert responses_for(slug) == []
  end

  test "oversize inputs are capped, junk value types dropped", %{conn: conn} do
    slug = seed_paper!(form_blocks())
    long = String.duplicate("a", 5_000)

    conn
    |> post(path(slug), %{
      "answers" => %{"q-notes" => long, "q-fit" => %{"nested" => "junk"}}
    })
    |> json_response(201)

    assert [doc] = responses_for(slug)
    assert String.length(doc.content["answers"]["q-notes"]) == 4_000
    refute Map.has_key?(doc.content["answers"], "q-fit")
  end

  test "forms nested inside containers are still discovered", %{conn: conn} do
    slug =
      seed_paper!([
        %{"id" => "cols", "type" => "columns", "columns" => [form_blocks(), []]}
      ])

    assert %{"ok" => true} =
             conn
             |> post(path(slug), %{"answers" => %{"q-fit" => "No"}})
             |> json_response(201)
  end

  test "the form_response schema is private: anonymous read API never serves responses", %{
    conn: conn
  } do
    slug = seed_paper!(form_blocks())

    %{"ok" => true, "id" => id} =
      conn
      |> post(path(slug), %{"answers" => %{"q-fit" => "Yes"}})
      |> json_response(201)

    anon = scoped_conn()
    resp = anon |> get("/v1/data/doc/production/form_response/#{id}")
    assert resp.status in [401, 403, 404]
  end

  # The 20-submission cap used to key on `conn.remote_ip`, which behind the
  # co-located Caddy (every prod instance reverse-proxies `localhost:4000`) is
  # always 127.0.0.1 — so it was ONE global budget for the entire internet and a
  # single abuser closed every public form on the box for everyone.
  #
  # PROTECTIVE, not vacuous: restore `conn.remote_ip |> :inet.ntoa()` and this
  # test REDS on the very first assertion of the second caller — B is refused
  # because A already drained the single loopback bucket.
  #
  # Honeypot submissions are billed by `rate_limit/1` BEFORE `honeypot/1`
  # short-circuits, so the cap can be drained 20 times without a paper, a
  # question allowlist, or a single row written.
  describe "the per-address submission cap behind a trusted front" do
    @front_caller_a "198.51.100.20"
    @front_caller_b "198.51.100.21"

    defp spam(conn, ip) do
      conn
      # Loopback peer + an appended chain: the exact shape Caddy delivers.
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", ip)
      |> post(path("no-such-paper"), %{"website" => "spam.example"})
    end

    test "one caller draining its 20 submissions does not close the form for another", %{
      conn: conn
    } do
      for _ <- 1..20, do: assert(spam(conn, @front_caller_a).status == 201)

      # A is spent...
      refused = spam(conn, @front_caller_a)
      assert refused.status == 429
      assert json_response(refused, 429)["error"]["code"] == "rate_limited"

      # ...and B, arriving through the identical front, is untouched.
      assert spam(conn, @front_caller_b).status == 201
    end
  end
end
