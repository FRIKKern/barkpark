defmodule BarkparkWeb.Studio.GrantWriteTargetLadderOwnerTest do
  @moduledoc """
  task-781468f003071830 — ONE owner for the grant write-TARGET ladder, and the
  ONE difference between its two callers, asserted by run.

  ## The unification

  The per-target containment walk over `Access.validate/3` used to be stated
  TWICE: `Shared.Paper.grant_target_denied?/3` (paper `handle_info` doors,
  wave 44) and `Shared.sheet_grant_target_denied?/1` (the SheetGrid component
  route, wave 41 — bolted on as a second copy because the paper copy was a
  `defp`). Both now call `Caps.grant_target_denied?/4`.

  ## THE ONE DIFFERENCE, AND WHY IT IS NOT A FORK

  The owner TAKES THE GRANT LIST as an argument, so the surfaces differ only in
  what they hand it:

    * PAPER — `handle_info`, so it passes a FRESH
      `Access.list_active_grants_for_grantee/1` load and a grant REVOKED
      mid-session stops admitting on the very next op;
    * SHEET — `render/1`, where a `Repo` round trip per parent render is
      prohibited, so it passes the grants CAPTURED in `caller_context`. A grant
      revoked mid-session is still in that captured list, with `revoked_at: nil`
      on the struct, so `Access.validate/3` (which reads the STRUCT's
      `revoked_at`) still says `:ok` there.

  That second answer is NOT a hole: the sheet snapshot is a UI AFFORDANCE, and
  expiry/revocation truth reaches the real sheet write seam through
  `Caps.write_capable_now?/1` (a fresh derive) before any mutation. The tests
  below pin BOTH answers, because a hoist that silently equalised them would be
  a behaviour change wearing a refactor's clothes.

  ## The controls

  Every "denied" assertion is paired with a "granted" positive control through
  the SAME entry point, so "the ladder denies" cannot be confused with "the
  ladder denies everything". Those positive controls are also what goes RED on
  BOTH surfaces when the owner's single `Access.validate/3` line is mutated —
  the non-vacuity proof that there is now exactly one walk.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @granted_slug "ladder-owner-granted"
  @other_slug "ladder-owner-other"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    user = register_user("ladder-owner-#{System.unique_integer([:positive])}@example.com")

    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

    grant =
      bind_grant!(ws, user, %{
        capabilities: ["read", "write"],
        project_id: proj.id,
        dataset: @dataset,
        type: "sheet",
        doc_id: @granted_slug
      })

    %{ws: ws, proj: proj, user: user, grant: grant}
  end

  # The GRANT grade, spelled the way `LiveScope.assign_grant_scope/2` +
  # `attach_write_gate/2` spell it. `caller_context.grants` is the CAPTURED set —
  # exactly what the sheet render path reads.
  defp grant_graded_assigns(%{ws: ws, proj: proj, user: user, grant: grant}, extra \\ %{}) do
    Map.merge(
      %{
        current_workspace: ws,
        current_project: proj,
        current_user: user,
        dataset: @dataset,
        caller_context: %{grants: [grant]},
        write_gate?: true
      },
      extra
    )
  end

  defp socket(assigns), do: %{assigns: assigns}

  defp sheet_assigns(ctx, slug, extra) do
    grant_graded_assigns(
      ctx,
      Map.merge(%{sheet_doc: %{type: "sheet", doc_id: slug}}, extra)
    )
  end

  defp revoke!(grant) do
    {:ok, _} =
      grant
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update()

    :ok
  end

  describe "ONE OWNER — both surfaces route through Caps.grant_target_denied?/4" do
    test "the doc the grant NAMES is admitted on both surfaces", ctx do
      refute Paper.grant_target_denied?(socket(grant_graded_assigns(ctx)), "sheet", @granted_slug)

      assert Shared.sheet_write_capable_snapshot?(
               sheet_assigns(ctx, @granted_slug, %{caps: %{write: true}})
             )
    end

    test "a DIFFERENT doc on the same desk is refused on both surfaces", ctx do
      assert Paper.grant_target_denied?(socket(grant_graded_assigns(ctx)), "sheet", @other_slug)

      refute Shared.sheet_write_capable_snapshot?(
               sheet_assigns(ctx, @other_slug, %{caps: %{write: true}})
             )
    end

    test "a MEMBERSHIP-graded socket never reaches the walk at all", ctx do
      membership =
        ctx
        |> grant_graded_assigns()
        |> Map.drop([:caller_context])
        |> Map.put(:write_gate?, nil)

      refute Caps.grant_graded?(membership)
      refute Paper.grant_target_denied?(socket(membership), "sheet", @other_slug)
    end

    test "an unresolvable target FAILS CLOSED for a grant-graded socket", ctx do
      no_project = ctx |> grant_graded_assigns() |> Map.put(:current_project, nil)
      assert Paper.grant_target_denied?(socket(no_project), "sheet", @granted_slug)

      # A sheet doc carrying no leaf at all: `Caps.doc_leaf/1` reads it totally
      # (no KeyError) and the nils make the target unresolvable.
      assert Caps.doc_leaf(nil) == {nil, nil}

      refute Shared.sheet_write_capable_snapshot?(
               ctx
               |> grant_graded_assigns(%{caps: %{write: true}})
               |> Map.put(:sheet_doc, nil)
             )
    end
  end

  describe "THE PRESERVED DIFFERENCE — fresh reload vs captured grants" do
    test "a grant REVOKED mid-session denies the PAPER path and NOT the sheet snapshot",
         ctx do
      paper_socket = socket(grant_graded_assigns(ctx))
      sheet = sheet_assigns(ctx, @granted_slug, %{caps: %{write: true}})

      # CONTROL — before the revocation both surfaces admit this exact target.
      refute Paper.grant_target_denied?(paper_socket, "sheet", @granted_slug)
      assert Shared.sheet_write_capable_snapshot?(sheet)

      revoke!(ctx.grant)

      # PAPER: the fresh, active-filtered reload no longer returns the grant, so
      # the walk has nothing to admit with. This is the whole reason the paper
      # surface loads rather than captures.
      assert Paper.grant_target_denied?(paper_socket, "sheet", @granted_slug),
             "the paper door must see a mid-session revocation on its very next op"

      # SHEET: the captured struct still carries `revoked_at: nil`, so the same
      # owner, walked over the captured list, still admits. Preserved, not fixed —
      # the real sheet seam re-derives through `Caps.write_capable_now?/1`.
      assert Shared.sheet_write_capable_snapshot?(sheet),
             "the render-time snapshot must stay query-free and therefore stale"
    end

    test "the difference is the ARGUMENT, not the owner — the same call answers both ways",
         ctx do
      assigns = grant_graded_assigns(ctx)
      captured = assigns.caller_context.grants

      revoke!(ctx.grant)

      fresh = Barkpark.Access.list_active_grants_for_grantee(ctx.user.id)

      # Same function, same assigns, same target — two grant lists, two answers.
      refute Caps.grant_target_denied?(assigns, captured, "sheet", @granted_slug)
      assert Caps.grant_target_denied?(assigns, fresh, "sheet", @granted_slug)

      refute Enum.any?(fresh, &(&1.id == ctx.grant.id))
    end
  end
end
