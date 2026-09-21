defmodule BarkparkWeb.Studio.CapsWriteTargetDatasetConjunctTest do
  @moduledoc """
  task-ff06f7114313ebaa — THE INVARIANT, stated without naming a mechanism:

    A socket whose write authority descends from a GRANT may not be admitted to
    a write whose target it cannot fully resolve. A target whose dataset is
    unresolved — absent, nil, or not a string — is one such target, and the
    answer for it is DENY.

  That sentence names no function, no module and no rung of any containment
  ladder on purpose. Moving the resolution check anywhere else — into the
  access validator, into the mount-time scope builder, into a caller — does not
  satisfy it; only an actual DENY on an unresolved-dataset target does. The
  assertions below therefore drive PUBLIC doors and read their boolean, never a
  private helper.

  ## Why this file exists

  The grant door's own docstring advertises "FAIL-CLOSED on an unresolvable
  target (no workspace / project / dataset / type / doc_id) for a socket that IS
  grant-graded". Every other component of that promise is driven by an existing
  case; the DATASET component was not. The seven-file grant-door population
  (every file mentioning grant_target_denied?, write_target_scope, grant_graded?
  or doc_leaf) stayed at 0 failures with the dataset check deleted, while the
  same population reds 2 when a different conjunct of the same module is
  deleted — so the population is live and was simply blind here.

  It was blind because every grant-door fixture in it assigns a BINARY dataset.
  The check can only be the discriminator on a socket where the dataset is NOT
  one, so no existing fixture could move it.

  ## The shape that makes the dataset the only moving part

  One grant-graded socket and ONE write grant scoped at the WORKSPACE with a nil
  dataset. A workspace-scoped grant with a nil dataset covers every dataset
  beneath it, so the containment walk stops being able to refuse on the dataset
  value itself — which is exactly what makes the RESOLUTION of that value the
  only thing left that can decide, and what makes an unresolved dataset
  admitted rather than merely re-denied when the check is removed.

  The arms below share that socket and that grant verbatim; between the admitted
  arm and each denied arm exactly one thing differs, the `:dataset` assign.

  NO ESCALATION IS CLAIMED. A dataset-nil grant already covers every dataset
  under its workspace, so a write admitted this way stays inside the grant's own
  scope, and a grant that NAMES a dataset refuses an unresolved one on
  containment regardless. What is defective is the ASSERTION — the documented
  fail-closed posture — not the access. This file makes that word measurable.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @type_name "paper"
  @doc_slug "caps-dataset-conjunct-doc"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    user = register_user("caps-dataset-#{System.unique_integer([:positive])}@example.com")

    # THE ONE GRANT. Workspace-scoped, write-capable, and NIL at every level
    # below the workspace — project, dataset, type and doc_id all unset.
    grant = bind_grant!(ws, user, %{capabilities: ["read", "write"]})

    %{ws: ws, proj: proj, user: user, grant: grant}
  end

  # The grant grade spelled the way the mount spells it: `caller_context` from
  # the grant-scope assign and `write_gate?` from the write-gate attach.
  defp base_assigns(%{ws: ws, proj: proj, user: user, grant: grant}) do
    %{
      current_workspace: ws,
      current_project: proj,
      current_user: user,
      dataset: @dataset,
      caller_context: %{grants: [grant]},
      write_gate?: true
    }
  end

  defp grants(%{grant: grant}), do: [grant]

  defp denied?(assigns, ctx),
    do: Caps.grant_target_denied?(assigns, grants(ctx), @type_name, @doc_slug)

  # THE SETUP IS ASSERTED, NOT ASSUMED. If any of these stops holding, the arms
  # below would still print a verdict while measuring something else.
  defp assert_preconditions!(ctx) do
    assert ctx.grant.workspace_id == ctx.ws.id
    assert is_nil(ctx.grant.project_id)
    assert is_nil(ctx.grant.dataset)
    assert is_nil(ctx.grant.type)
    assert is_nil(ctx.grant.doc_id)
    assert "write" in ctx.grant.capabilities
    assert Caps.grant_graded?(base_assigns(ctx))
    :ok
  end

  describe "an unresolved dataset on a grant-graded socket" do
    test "ADMITTED with a binary dataset, DENIED with nil — nothing else differs", ctx do
      assert_preconditions!(ctx)

      admitted = base_assigns(ctx)
      unresolved = Map.put(admitted, :dataset, nil)

      # The two maps differ in exactly one key, proved by run rather than by
      # reading the constructors.
      assert Map.keys(admitted) == Map.keys(unresolved)

      assert [:dataset] ==
               Enum.filter(
                 Map.keys(admitted),
                 &(Map.get(admitted, &1) != Map.get(unresolved, &1))
               )

      # POSITIVE CONTROL — the grant really does admit this target, so the deny
      # on the next line cannot be "the grant refuses everything".
      refute denied?(admitted, ctx)

      # THE INVARIANT.
      assert denied?(unresolved, ctx)
    end

    test "DENIED when the :dataset key is ABSENT ENTIRELY — the guard is total", ctx do
      assert_preconditions!(ctx)

      absent = ctx |> base_assigns() |> Map.delete(:dataset)

      refute Map.has_key?(absent, :dataset)
      refute denied?(base_assigns(ctx), ctx)

      assert denied?(absent, ctx)
    end

    test "DENIED when the dataset is present but NOT A STRING", ctx do
      assert_preconditions!(ctx)

      assert denied?(Map.put(base_assigns(ctx), :dataset, :production), ctx)
      assert denied?(Map.put(base_assigns(ctx), :dataset, 1), ctx)
      assert denied?(Map.put(base_assigns(ctx), :dataset, %{name: @dataset}), ctx)
    end

    test "the same three answers arrive through the PAPER write seam", ctx do
      assert_preconditions!(ctx)

      # A caller, not the owner: this door loads the grantee's ACTIVE grants
      # itself, so the arms below also prove the socket's own grant population
      # is the dataset-nil one and not a fixture artefact of the list argument.
      socket = fn assigns -> %{assigns: assigns} end

      refute Paper.grant_target_denied?(socket.(base_assigns(ctx)), @type_name, @doc_slug)

      assert Paper.grant_target_denied?(
               socket.(Map.put(base_assigns(ctx), :dataset, nil)),
               @type_name,
               @doc_slug
             )

      assert Paper.grant_target_denied?(
               socket.(ctx |> base_assigns() |> Map.delete(:dataset)),
               @type_name,
               @doc_slug
             )
    end
  end

  describe "the arm stays INERT for a socket that is not grant-graded" do
    test "an unresolved dataset is not this door's business without a grant grade", ctx do
      membership =
        ctx
        |> base_assigns()
        |> Map.drop([:caller_context])
        |> Map.put(:write_gate?, nil)
        |> Map.put(:dataset, nil)

      refute Caps.grant_graded?(membership)
      refute denied?(membership, ctx)
    end
  end
end
