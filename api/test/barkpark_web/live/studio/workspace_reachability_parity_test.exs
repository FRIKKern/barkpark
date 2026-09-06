defmodule BarkparkWeb.Studio.WorkspaceReachabilityParityTest do
  @moduledoc """
  `arpss-w10-bl-member-only-predicate-drift-pairs` — the scope-switcher
  reachability rule has ONE implementation, and this file is what stops it
  growing a second.

  `StudioChrome.can_reach?/2` and
  `StudioLive.Shared.can_reach_workspace?/2` were byte-identical bodies in two
  files (token -> `Tenancy.Auth.member?/2`; anything else -> identity match on
  the mounted `current_workspace`), with nothing pinning them together. Neither
  is an admit-direction bug on its own — the destination mount re-gates — but an
  unpinned duplicate is the drift hazard: tighten the switcher in one file and
  the other keeps admitting, silently.

  Two halves, and BOTH are needed:

    * `the rule` — the three principal shapes the predicate actually
      discriminates, asserted against the owner. Tightening or loosening the
      owner reds here.
    * `the delegation` — `StudioChrome`'s arm is a ONE-LINE call to the owner,
      asserted over the source. Re-inlining a copy in the chrome reds here even
      though the copy would agree with the owner on the day it is written; that
      agreement is exactly what a drift test cannot assume.

  A behavioural equivalence test alone cannot catch the second failure, and the
  source pin alone cannot catch the first — which is why neither is dropped.

  ALSO PINNED, and the reason this is not a three-line dedup:
  `StudioChrome.can_create_in?/2` sits seven lines above `can_reach?/2` and is
  DELIBERATELY a different question — membership asked of the principal's OWN
  kind on BOTH arms, so the account arm does not inherit the anonymous "is this
  the workspace I am already mounted in?" fallback that every mounted account
  session answers yes to. `does not fold in the create gate` asserts it is still
  its own predicate, because folding it into the dedup would silently re-open
  that hole.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.{Repo, Tenancy}
  alias BarkparkWeb.Studio.StudioLive.Shared

  @chrome_src "lib/barkpark_web/studio_chrome.ex"

  setup do
    {ws, _proj} = ensure_default_scope!()
    other = create_workspace!("reach-other-#{System.unique_integer([:positive])}")
    {:ok, ws: ws, other: other}
  end

  defp token!(label) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("reach-" <> Ecto.UUID.generate()),
        label: label,
        dataset: "production",
        permissions: ["read"]
      })
      |> Repo.insert()

    token
  end

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, api_token: nil, current_workspace: nil}, assigns)
    }
  end

  describe "the rule — the three principal shapes" do
    test "an ApiToken MEMBER of the workspace reaches it", %{ws: ws} do
      token = token!("reach-member")
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")

      assert Shared.can_reach_workspace?(socket(%{api_token: token}), ws)
    end

    test "an ApiToken NON-member does NOT reach it — and its own mounted workspace does not rescue it",
         %{ws: ws} do
      token = token!("reach-nonmember")

      refute Shared.can_reach_workspace?(socket(%{api_token: token}), ws)

      # The token arm RETURNS: a token that is mounted in `ws` but not a member
      # must NOT fall through to the anonymous identity fallback.
      refute Shared.can_reach_workspace?(
               socket(%{api_token: token, current_workspace: ws}),
               ws
             )
    end

    test "an ANONYMOUS socket reaches exactly the workspace it is mounted in", %{
      ws: ws,
      other: other
    } do
      anon = socket(%{current_workspace: ws})

      assert Shared.can_reach_workspace?(anon, ws)
      refute Shared.can_reach_workspace?(anon, other)
      refute Shared.can_reach_workspace?(socket(%{}), ws)
    end
  end

  describe "the delegation — one implementation, not two agreeing copies" do
    test "StudioChrome.can_reach?/2 is a one-line call to the owner" do
      src = File.read!(@chrome_src)

      assert src =~
               "defp can_reach?(socket, workspace), do: Shared.can_reach_workspace?(socket, workspace)",
             "StudioChrome.can_reach?/2 must stay a one-line delegation to " <>
               "Shared.can_reach_workspace?/2 (@canonical " <>
               "capability:studio-workspace-reachability). A second copy of the " <>
               "body here is the drift hazard arpss-w10 filed, even if it agrees today."

      refute src =~ ~r/defp can_reach\?\(socket, %\{id: ws_id\}\)/,
             "the byte-copy of the reachability body is back in studio_chrome.ex"
    end

    test "does not fold in the create gate — can_create_in?/2 is still its own predicate" do
      src = File.read!(@chrome_src)

      assert src =~ "defp can_create_in?(socket, %{id: ws_id}) do",
             "can_create_in?/2 must NOT be folded into the reachability dedup: " <>
               "it asks membership of the principal's OWN kind on both arms, " <>
               "precisely so the account arm does not inherit can_reach?/2's " <>
               "anonymous 'already mounted here' fallback."

      assert src =~ "Tenancy.Auth.member?(principal, ws_id)",
             "can_create_in?/2's account arm must stay a membership test"
    end
  end

  describe "the owner is marked" do
    test "Shared.can_reach_workspace?/2 carries the @canonical marker" do
      assert File.read!("lib/barkpark_web/live/studio/studio_live/shared.ex") =~
               "@canonical capability:studio-workspace-reachability"
    end
  end
end
