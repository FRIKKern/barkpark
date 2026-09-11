defmodule BarkparkWeb.BulldocsIngestDedupOutageTest do
  @moduledoc """
  THE DEDUP OUTAGE, PROVED FROM THE WIRE (dr-w32-bl-dedup-outage-unreachable-from-http).

  `BulldocsIngestController` carries four `{:error, {:dedup_unavailable, _}}`
  arms — the ONE wall shape that is a transient OUTAGE rather than a policy
  refusal — and until this file NO request could reach any of them:
  `DedupWall` degraded only on a non-string dataset or an explicit
  `dedup_timeout_ms` opt, and neither is settable through an HTTP body. So the
  503 envelope those arms render was asserted nowhere above the unit level,
  which is exactly how this shape once shipped as a 409 plugin-veto.

  `DedupWall`'s timeout resolution now takes its DEFAULT from
  `Application.get_env(:barkpark, :dedup_timeout_ms)`, and that read is compiled
  out of every non-`:test` build (see the seam comment in `dedup_wall.ex`), so a
  ConnCase can drive the real stack into a degraded scan while production keeps
  a literal constant. A `0` budget is refused BEFORE the pool is touched —
  deterministic, never a checkout race.

  ## The four arms, and what each leg actually answers

  | leg | controller fn | under the outage |
  |---|---|---|
  | `POST /bulldocs/papers` (blocks) | `ingest_blocks/4` | **503, arm reached** |
  | `POST /bulldocs/papers` (body_html) | `ingest_html_write/2` | **503, arm reached** |
  | `POST /bulldocs/papers/:slug/sync` (create-on-push) | `sync_create/5` | **503, outage lifted out of the wall fold** |
  | `POST /bulldocs/sessions` | `ingest_session/2` | 200 — arm UNREACHABLE (dead code) |

  ## What changed on the sync door, and why this file's own pin was replaced

  #17688 (this file's first version) PINNED the sync door's 422: `sync_create/5`
  is validate-FIRST, `AuthoringWall.validate_all/5` collects the dedup gate's
  tuple like any other, and the fold turned a transient OUTAGE into an
  author-fixable `create_wall` refusal. That pin recorded a defect it did not
  own. It is now superseded IN PLACE (task-1f147feee2f5f43a) rather than
  duplicated: `sync_create/5` lifts `{:dedup_unavailable, reason}` out of the
  tuple list BEFORE the violation fold and answers through the same
  `dedup_unavailable_error/2` builder the blocks and body_html legs use. One
  envelope, one owner, three live doors.

  The persist arm's own `{:error, {:dedup_unavailable, _}}` (in
  `sync_create_persist/6`) stays: it is the RACE path — an outage that begins
  after the precheck passed and before `upsert_paper/1`'s authoritative
  recheck — which no deterministic request-level override can stage, so it is
  not asserted here.

  The validate DRY-RUN (`POST /bulldocs/papers/validate`) is deliberately NOT
  changed: it always answers 200 `{valid, violations}` and renders verdicts as
  data, never transport positions.

  The remaining unreachable arm is pinned by the behaviour that PREEMPTS it, so
  the day that precondition changes this file reds instead of going quiet:

    * **sessions.** `AuthoringWall`'s `@walled_types` is `~w(paper task)`, so a
      `session` write never runs the dedup gate at all. Its arm is deliberate
      shape-parity dead code (the controller says so). The outage therefore
      changes nothing on that leg — asserted, not assumed.

  Every outage assertion is paired with a CONTROL that runs the identical POST
  with the override unset and gets a 2xx, so no test here can pass by the leg
  being broken for some other reason.

  `async: false`: `Application.put_env/3` is global. ExUnit runs sync cases
  after every async case has finished, so the override cannot reach an async
  neighbour, and `on_exit` deletes it either way.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"
  @sessions_path "/v1/plugins/bulldocs/sessions"
  @dataset "production"

  # The wire shape errors.ex:777 builds for {:error, {:dedup_unavailable, _}}:
  # ONE public code per status, so the arm wears the already-registered
  # transient-storage code and discriminates itself on `reason`.
  @code "storage_unavailable"
  @reason "dedup_unavailable"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp labels do
    labels = LabelFixtures.paper_attrs(%{"dataset" => @dataset})
    %{"tags" => labels["tags"], "description" => labels["description"]}
  end

  defp title_block(text) do
    %{"id" => "tpl-title", "type" => "heading", "level" => 1, "text" => text}
  end

  defp blocks_body(slug) do
    %{"tags" => tags, "description" => description} = labels()

    %{
      "slug" => slug,
      "blocks" => [
        title_block("Dedup outage #{slug}"),
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Body for the outage proof #{slug}."}]
        }
      ],
      "tags" => tags,
      "description" => description
    }
  end

  defp html_body(slug) do
    %{"tags" => tags, "description" => description} = labels()

    %{
      "slug" => slug,
      "body_html" => "<article><h1>Dedup outage #{slug}</h1><p>Legacy body.</p></article>",
      "tags" => tags,
      "description" => description
    }
  end

  # THE OUTAGE SWITCH. A non-positive budget can only ever mean "the scan did
  # not happen" — DedupWall says so before touching the pool, so this is a
  # decision, not a race.
  defp degrade_dedup! do
    Application.put_env(:barkpark, :dedup_timeout_ms, 0)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:barkpark, :dedup_timeout_ms) end)
  end

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "the blocks ingest leg (ingest_blocks/4)" do
    test "a dedup outage answers 503 storage_unavailable / dedup_unavailable with retry wording",
         %{conn: conn} do
      s = slug("dedup-outage-blocks")
      degrade_dedup!()

      conn = authed(conn) |> post(@path, blocks_body(s))

      assert %{"error" => err} = json_response(conn, 503)
      assert err["code"] == @code
      assert err["reason"] == @reason

      # The message is the wall's own sentence: it names what did not happen
      # and never claims the document is a duplicate.
      assert err["message"] =~ "publish dedup wall could not complete"
      assert err["message"] =~ "no time to run (0ms budget)"
      assert err["message"] =~ "REFUSED"

      # RETRY-SHAPED, both in prose and machine-readably. This is the half that
      # separates an outage from the 409 plugin-veto this used to wear.
      assert err["hint"] =~ "Transient"
      assert err["hint"] =~ "Resend the identical request"
      assert err["hint"] =~ "outage to report, not a document to fix"

      # THE CONTROLLER ARM'S OWN CONTRIBUTION, asserted separately. The shared
      # envelope (errors.ex) already carries the 503 and a generic transient
      # hint ("this WRITE was neither stored nor refused"), so deleting the arm
      # does NOT restore a 500 — it silently drops the paper-specific sentence
      # and the machine-readable `retry-after`. These two lines are what red
      # when the arm goes.
      assert err["hint"] =~ "this paper was neither written nor refused"
      assert get_resp_header(conn, "retry-after") == ["5"]

      # Fail-CLOSED: refused, never written. A wall that could not look must not
      # wave the publish through.
      refute Content.get_paper(s, @dataset)
    end

    test "CONTROL: the identical POST with no override publishes (200)", %{conn: conn} do
      s = slug("dedup-control-blocks")

      conn = authed(conn) |> post(@path, blocks_body(s))

      assert %{"ok" => true, "slug" => ^s} = json_response(conn, 200)
      assert Content.get_paper(s, @dataset).status == "published"
    end
  end

  describe "the legacy body_html ingest leg (ingest_html_write/2)" do
    test "a dedup outage answers the SAME 503 envelope on the second head", %{conn: conn} do
      s = slug("dedup-outage-html")
      degrade_dedup!()

      conn = authed(conn) |> post(@path, html_body(s))

      assert %{"error" => err} = json_response(conn, 503)
      assert err["code"] == @code
      assert err["reason"] == @reason
      assert err["message"] =~ "publish dedup wall could not complete"
      assert err["hint"] =~ "Resend the identical request"
      assert get_resp_header(conn, "retry-after") == ["5"]

      refute Content.get_paper(s, @dataset)
    end

    test "CONTROL: the identical POST with no override publishes (200)", %{conn: conn} do
      s = slug("dedup-control-html")

      conn = authed(conn) |> post(@path, html_body(s))

      assert %{"ok" => true, "slug" => ^s} = json_response(conn, 200)
      assert Content.get_paper(s, @dataset).status == "published"
    end
  end

  describe "the create-on-push leg (sync_create/5)" do
    defp sync_conn(conn, s, bpml) do
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")
      |> post("#{@path}/#{s}/sync", %{"bpml" => bpml, "baseRev" => "0"})
    end

    defp create_bpml(s) do
      n = System.unique_integer([:positive])
      names = ["qz#{n}outage", "qz#{n}proof"]
      LabelFixtures.register_tags!(@dataset, names)

      tag_lines =
        names
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {name, i} ->
          ~s(    <tag tag="#{name}" strength="#{90 - i * 30}">Outage-door fixture tag — proves the create leg's ordering.</tag>)
        end)

      """
      <paper slug="#{s}" title="Outage Door zq#{n}x">
        <meta>
          <description>Outage-door proof zq#{n}a zq#{n}b zq#{n}c zq#{n}d zq#{n}e.</description>
      #{tag_lines}
        </meta>
        <h1>Outage Door zq#{n}x</h1>
        <p>The create door runs the wall before it persists zq#{n}f zq#{n}g.</p>
      </paper>
      """
    end

    test "a dedup outage answers the SAME 503 envelope as the ingest legs, never 422 create_wall",
         %{conn: conn} do
      s = slug("dedup-outage-sync")
      bpml = create_bpml(s)
      degrade_dedup!()

      conn = sync_conn(conn, s, bpml)

      # NOT 422. `sync_create/5` lifts `{:dedup_unavailable, _}` out of
      # `validate_all/5`'s tuple list before the violation fold, so the outage
      # wears its own transport status instead of the create door's.
      assert %{"error" => err} = json_response(conn, 503)
      assert err["code"] == @code
      assert err["reason"] == @reason

      # BYTE-FOR-BYTE the ingest legs' envelope, because it is literally the
      # same builder (`dedup_unavailable_error/2`). If these drift, two doors
      # are describing one outage two ways.
      assert err["message"] =~ "publish dedup wall could not complete"
      assert err["message"] =~ "no time to run (0ms budget)"
      assert err["message"] =~ "REFUSED"
      assert err["hint"] =~ "Transient"
      assert err["hint"] =~ "Resend the identical request"
      assert err["hint"] =~ "this paper was neither written nor refused"
      assert err["hint"] =~ "outage to report, not a document to fix"
      assert get_resp_header(conn, "retry-after") == ["5"]

      # The 422 is GONE, not merely deprioritised — asserted on the negative
      # so a future re-fold cannot pass this test by answering both shapes.
      refute err["code"] == "create_wall"
      refute Map.has_key?(err, "errors")

      # Fail-CLOSED and validate-FIRST: nothing written, no draft row either.
      refute Content.get_paper(s, @dataset)
      refute Content.get_paper("drafts.#{s}", @dataset)
    end

    test "CONTROL: the identical push with no override CREATES the paper (200)", %{conn: conn} do
      s = slug("dedup-control-sync")

      conn = sync_conn(conn, s, create_bpml(s))

      assert %{"ok" => true, "created" => true, "slug" => ^s} = json_response(conn, 200)
    end
  end

  describe "the session leg (ingest_session/2) — arm documented UNREACHABLE" do
    test "a session write is unwalled, so the outage does not touch it (200)", %{conn: conn} do
      s = slug("dedup-outage-session")
      degrade_dedup!()

      conn =
        authed(conn)
        |> post(@sessions_path, %{
          "slug" => s,
          "title" => "Outage session #{s}",
          "blocks" => [title_block("Outage session")]
        })

      # `@walled_types` is ~w(paper task): the dedup gate never runs for a
      # session, so its `{:error, {:dedup_unavailable, _}}` arm is dead code
      # kept for shape-parity. The day a walled blocks-type joins the
      # whitelist, this assertion flips and the arm becomes live.
      assert %{"ok" => true, "slug" => ^s} = json_response(conn, 200)
    end
  end
end
