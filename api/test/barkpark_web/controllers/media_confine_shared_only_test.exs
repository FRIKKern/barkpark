defmodule BarkparkWeb.MediaConfineSharedOnlyTest do
  @moduledoc """
  `BarkparkWeb.MediaController`'s unscoped-read confinement must honour the
  `:shared_only` sentinel (task-5ca36b127acf9cbd, SITE 3).

  ## The defect

  `scope_bound?/1` was `not is_nil(Keyword.get(opts, :workspace_id))`. It was
  written when an unresolved request produced NO `:workspace_id` key, so `nil`
  was the only way to say "no tenant resolved". `ScopeHelpers` later gave that
  state a name — `workspace_id: :shared_only` — and `not is_nil(:shared_only)`
  is TRUE, so `confine_one/2` and `confine_many/2` no-opped on precisely the
  request they exist to confine. A fail-open shape, reporting the opposite of
  the truth.

  ## What is NOT claimed

  No exploitable leak. `Media.get_file/2` and `Media.list_files/2` both hand
  the sentinel to `Content.Scope.scope_to_workspace_or_global/3`, which owns a
  `:shared_only` arm, so every read below narrows on its own today. This layer
  is defence-in-depth; the reason to repair it is that the NEXT flat read added
  to that controller is the one that inherits the shape.

  Tested at the predicate and its two consumers rather than over HTTP for that
  exact reason: an end-to-end arm would be VACUOUS — the underlying read
  already excludes the row, so the assertion would pass with the defect intact
  (`a-different-filter-can-make-your-fence-test-vacuous`). Each arm below reds
  when the `is_binary/1` guard is reverted to `not is_nil/1`.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media.Storage.MediaFile
  alias BarkparkWeb.MediaController
  alias BarkparkWeb.ScopeHelpers

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)

    {:ok, owned} = create_media_file_in!(ws, proj)
    shared = %MediaFile{owned | id: Ecto.UUID.generate(), workspace_id: nil, project_id: nil}

    {:ok, ws: ws, owned: owned, shared: shared}
  end

  describe "the producer really emits the sentinel on this controller's flat routes" do
    test "an unresolved conn carries :shared_only, not an omitted key" do
      # If this ever stops holding, every arm below goes vacuous — it is the
      # premise, asserted rather than assumed.
      assert Keyword.get(ScopeHelpers.scope_opts(%Plug.Conn{assigns: %{}}), :workspace_id) ==
               :shared_only
    end
  end

  describe "scope_bound?/1" do
    test "the :shared_only sentinel is NOT a bound scope" do
      refute MediaController.scope_bound?(workspace_id: :shared_only),
             "the sentinel read as 'scope bound', so the confinement below no-ops " <>
               "on exactly the unresolved request it exists to confine"
    end

    test "a real workspace id IS a bound scope", %{ws: ws} do
      assert MediaController.scope_bound?(workspace_id: ws.id)
    end

    test "an absent scope is NOT bound — the internal-caller behaviour is unchanged" do
      refute MediaController.scope_bound?([])
      refute MediaController.scope_bound?(workspace_id: nil)
    end
  end

  describe "confine_many/2 under the sentinel" do
    test "EXCLUDES a workspace-owned row and keeps the shared layer", %{
      owned: owned,
      shared: shared
    } do
      kept = MediaController.confine_many([workspace_id: :shared_only], [owned, shared])

      refute owned.id in Enum.map(kept, & &1.id),
             "an unresolved caller was handed a workspace-owned blob row"

      assert shared.id in Enum.map(kept, & &1.id),
             "the shared layer was dropped — a legacy single-tenant install loses its library"
    end

    test "NON-VACUITY: a bound scope passes BOTH rows through untouched", %{
      ws: ws,
      owned: owned,
      shared: shared
    } do
      # Proves the arm above discriminates on the SENTINEL and not on the
      # fixture: the same two rows survive a bound scope.
      kept = MediaController.confine_many([workspace_id: ws.id], [owned, shared])
      assert Enum.map(kept, & &1.id) == [owned.id, shared.id]
    end
  end

  describe "confine_one/2 under the sentinel" do
    test "REFUSES a workspace-owned row", %{owned: owned} do
      assert {:error, :not_found} =
               MediaController.confine_one([workspace_id: :shared_only], owned)
    end

    test "admits a shared-layer row", %{shared: shared} do
      assert {:ok, ^shared} = MediaController.confine_one([workspace_id: :shared_only], shared)
    end

    test "NON-VACUITY: a bound scope admits the workspace-owned row", %{ws: ws, owned: owned} do
      assert {:ok, ^owned} = MediaController.confine_one([workspace_id: ws.id], owned)
    end
  end
end
