defmodule BarkparkWeb.SurfaceHardTierTest do
  # async: false — the tier is an APPLICATION-ENV flag, which is global. An
  # async module flipping it would race every other module that files under
  # the epic, so this file owns the flag and runs alone.
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content

  # ── cch-w28-s4-followup: the HARD tier for an ABSENT surface ─────────────
  #
  # `Barkpark.Tasks.BirthGuards.surface_declared/6` warns and allows a
  # surface-less filing under the epic. The hard tier ships behind
  # `:filing_law_absent_surface_hard` (default false). These tests prove both
  # sides of the flag at the HTTP seam; the flag-on refusals go 200 when the
  # refusal arm is deleted.

  @epic "cloud-console-hardening-epic"
  @flag :filing_law_absent_surface_hard

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    previous = Application.fetch_env(:barkpark, @flag)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, @flag, value)
        :error -> Application.delete_env(:barkpark, @flag)
      end
    end)

    :ok
  end

  describe "flag OFF (the shipped default)" do
    setup do
      Application.delete_env(:barkpark, @flag)
      :ok
    end

    test "the default is off: nothing in config arms the tier" do
      # `setup` deleted the key; this guards the SHIPPED config files too.
      assert Application.get_env(:barkpark, @flag, false) == false
    end

    test "a surface-less create under the epic PASSES and logs the warn line",
         %{conn: conn} do
      log =
        capture_log([level: :warning], fn ->
          assert file_row(conn, "cchs4-off-absent", %{}).status == 200
        end)

      assert log =~
               "filing law: undeclared surface on epic task birth \"drafts.cchs4-off-absent\""

      assert log =~
               "(allowed; the backfill is not yet producible — 5 of 56 live orphans carry " <>
                 "one. Declare it with one of: console | instrument | ledger)"

      refute Map.has_key?(task_content("cchs4-off-absent"), "surface")
    end

    test "the off-vocabulary refusal still offers the omit-surface escape", %{conn: conn} do
      resp = file_row(conn, "cchs4-off-offvocab", %{"surface" => "dashboard"})

      assert resp.status == 422
      [message] = Jason.decode!(resp.resp_body)["error"]["details"]["surface"]
      assert message =~ "or omit `surface` entirely"
    end
  end

  describe "flag ON (the hard tier)" do
    setup do
      Application.put_env(:barkpark, @flag, true)
      :ok
    end

    test "a surface-less create under parent_id #{@epic} is REFUSED 422", %{conn: conn} do
      log =
        capture_log([level: :warning], fn ->
          resp = file_row(conn, "cchs4-on-absent", %{})

          assert resp.status == 422
          error = Jason.decode!(resp.resp_body)["error"]
          assert error["code"] == "validation_failed"
          assert [message] = error["details"]["surface"]
          assert message =~ "is required under \"#{@epic}\""
          assert message =~ ~s("console")
          assert message =~ ~s("instrument")
          assert message =~ ~s("ledger")
        end)

      # Refused, not warned: the warn line is the OTHER tier.
      refute log =~ "filing law: undeclared surface"
      assert missing?("cchs4-on-absent")
    end

    test "a BLANK surface is absent too", %{conn: conn} do
      assert_surface_refusal(file_row(conn, "cchs4-on-blank", %{"surface" => "   "}))
      assert missing?("cchs4-on-blank")
    end

    test "a sanctioned surface still files", %{conn: conn} do
      assert file_row(conn, "cchs4-on-ok", %{"surface" => "ledger"}).status == 200
      assert task_content("cchs4-on-ok")["surface"] == "ledger"
    end

    test "the scoping holds: a surface-less create OUTSIDE the epic passes", %{conn: conn} do
      assert create_row(conn, "cchs4-on-other", %{"parent_id" => "some-other-epic"}).status ==
               200

      assert create_row(conn, "cchs4-on-noparent", %{}).status == 200
    end

    test "the off-vocabulary refusal no longer advertises the omit escape", %{conn: conn} do
      resp = file_row(conn, "cchs4-on-offvocab", %{"surface" => "dashboard"})

      assert resp.status == 422
      [message] = Jason.decode!(resp.resp_body)["error"]["details"]["surface"]
      refute message =~ "omit `surface`"
      assert message =~ "also refuses an undeclared surface"
    end

    test "an update that STRIPS a declared surface is refused", %{conn: conn} do
      assert file_row(conn, "cchs4-on-strip", %{"surface" => "console"}).status == 200

      resp =
        mutate(conn, [
          %{"patch" => %{"id" => "cchs4-on-strip", "type" => "task", "unset" => ["surface"]}}
        ])

      assert_surface_refusal(resp)
      assert task_content("cchs4-on-strip")["surface"] == "console"
    end

    test "an update that RE-PARENTS a bare row under the epic is refused", %{conn: conn} do
      # Born ADJUDICATED, so the adoption fence (a reparent of an unjudged row
      # is refused for its own reason) is out of the way and the 422 below can
      # only be this guard's.
      assert create_row(conn, "cchs4-on-reparent", %{"disposition" => "open"}).status == 200

      resp = set_fields(conn, "cchs4-on-reparent", %{"parent_id" => @epic})

      assert_surface_refusal(resp)
      refute task_content("cchs4-on-reparent")["parent_id"] == @epic

      # CONTROL: the same adoption carrying a sanctioned surface lands, so the
      # refusal above is about the absence and nothing else.
      assert create_row(conn, "cchs4-on-reparent-ok", %{
               "disposition" => "open",
               "surface" => "console",
               # its title is a near-twin of the row above; the dedup fence is
               # not under test here
               "dedup_bypass" => true
             }).status == 200

      assert set_fields(conn, "cchs4-on-reparent-ok", %{"parent_id" => @epic}).status == 200
      assert task_content("cchs4-on-reparent-ok")["parent_id"] == @epic
    end

    test "a GRANDFATHERED bare epic row stays patchable on other fields", %{conn: conn} do
      # Born bare while the flag was off (the pre-backfill corpus).
      Application.put_env(:barkpark, @flag, false)
      assert file_row(conn, "cchs4-on-grandfathered", %{}).status == 200
      Application.put_env(:barkpark, @flag, true)

      assert set_fields(conn, "cchs4-on-grandfathered", %{"priority" => 3}).status == 200
      assert task_content("cchs4-on-grandfathered")["priority"] == 3

      # ...and the backfill itself is an ordinary patch.
      assert set_fields(conn, "cchs4-on-grandfathered", %{"surface" => "instrument"}).status ==
               200

      assert task_content("cchs4-on-grandfathered")["surface"] == "instrument"
    end
  end

  # ── fixtures (the mutate_controller_test filing-law block's shapes) ──────

  defp create_row(conn, id, content_extra) do
    mutate(conn, [
      %{
        "create" => %{
          "_id" => id,
          "_type" => "task",
          "title" => "Surface hard-tier fixture #{id}",
          "content" =>
            Map.merge(
              %{
                "kind" => "task",
                "brief" => Barkpark.TaskBriefFixtures.brief(),
                "lifecycle_status" => "open",
                "priority" => 1
              },
              content_extra
            )
        }
      }
    ])
  end

  defp file_row(conn, id, content_extra),
    do: create_row(conn, id, Map.put(content_extra, "parent_id", @epic))

  defp set_fields(conn, id, set),
    do: mutate(conn, [%{"patch" => %{"id" => id, "type" => "task", "set" => set}}])

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/test", Jason.encode!(%{"mutations" => mutations}))
  end

  defp task_content(id) do
    {:ok, doc} = Content.get_document("drafts.#{id}", "task", "test")
    doc.content
  end

  # A 422 for THIS reason: the absent-surface refusal, not some other wall.
  defp assert_surface_refusal(resp) do
    assert resp.status == 422
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "validation_failed"
    assert [message] = error["details"]["surface"]
    assert message =~ "is required under \"#{@epic}\""
  end

  defp missing?(id),
    do: match?({:error, _}, Content.get_document("drafts.#{id}", "task", "test"))
end
