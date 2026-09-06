defmodule BarkparkCloud.Registry.SiteShippedFrameworksTest do
  @moduledoc """
  ssw8-bl-accepted-frameworks-no-implementation — the DERIVATION gate behind the
  create door.

  `Site.shipped_frameworks/0` is a hand-written constant, because the control
  plane cannot read `templates/` at runtime: it is a repo-root tree that no
  release ships. A constant that names a filesystem it cannot see is exactly the
  over-claim this task is about, one level up — so this file closes the loop the
  only way a constant can be closed, by reading `templates/` off disk at TEST
  time and asserting the two agree in BOTH directions:

    * DECLARED -> ON DISK. Every slug in `shipped_starters/0` is a real starter
      tree. Delete `templates/astro-starter` and the door still promises astro.
    * ON DISK -> DECLARED. No framework the door REFUSES has grown a starter
      tree behind the constant's back. Land `templates/hugo-starter` and this
      reds, naming the framework to add — which is the whole point: the day hugo
      ships, the refusal must not silently outlive it.

  Non-vacuity is an explicit arm: if `templates/` is not where this file thinks
  it is, both directions above pass over an empty list and the gate is asleep.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.Site

  # cloud/test/barkpark_cloud/registry -> repo root.
  @templates Path.expand("../../../../templates", __DIR__)

  defp template_dirs do
    @templates
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@templates, &1)))
  end

  test "the templates/ tree this gate reads is actually there (non-vacuity)" do
    assert File.dir?(@templates),
           "expected the repo-root templates/ tree at #{@templates} — without it both " <>
             "directions below iterate an empty list and prove nothing"

    dirs = template_dirs()

    assert length(dirs) > 0, "templates/ has no starter directories at all"

    # A named anchor, so a tree that exists but has been emptied/renamed wholesale
    # cannot leave this gate green.
    assert "astro-starter" in dirs
  end

  test "DECLARED -> ON DISK: every shipped starter slug is a real tree" do
    dirs = template_dirs()

    for {framework, slug} <- Site.shipped_starters() do
      assert slug in dirs,
             "#{framework} is declared shipped with starter #{slug}, but " <>
               "templates/#{slug} does not exist — the create door promises a build " <>
               "the relay cannot provision"
    end
  end

  test "ON DISK -> DECLARED: no REFUSED framework has a starter tree" do
    dirs = template_dirs()
    refused = Site.frameworks() -- Site.shipped_frameworks()

    # The premise of the whole task: there ARE refused frameworks. If this list
    # empties (everything shipped), the arm below goes vacuous and should be
    # retired deliberately rather than kept as decoration.
    assert refused != []

    for framework <- refused do
      matching = Enum.filter(dirs, &String.contains?(&1, framework))

      assert matching == [],
             "templates/#{Enum.join(matching, ", templates/")} ships #{framework}, but the " <>
               "create door still refuses it — add #{inspect(framework)} to " <>
               "Site.@shipped_starters (or @starterless_frameworks) so the door catches up"
    end
  end

  test "the starterless frameworks genuinely need no tree" do
    # "static" is a folder of files the box serves as-is. It is shipped, and it
    # correctly has NO templates/ entry — assert that, so someone cannot quietly
    # move a framework into @starterless_frameworks to dodge the arm above.
    for framework <- Site.shipped_frameworks(),
        not Map.has_key?(Site.shipped_starters(), framework) do
      refute Enum.any?(template_dirs(), &String.contains?(&1, framework)),
             "#{framework} is declared starterless but templates/ carries a tree for it — " <>
               "it belongs in @shipped_starters, keyed to that slug"
    end
  end

  test "the shipped lists are strict subsets of the stored vocabulary" do
    # The door narrows; it must never widen. A framework the door accepts that
    # the schema would reject is an unreachable promise.
    assert Site.shipped_frameworks() -- Site.frameworks() == []
    assert Site.shipped_scale_modes() -- Site.scale_modes() == []
    assert Site.shipped_frameworks() != Site.frameworks()
    assert Site.shipped_scale_modes() != Site.scale_modes()
  end

  test "shipped_frameworks_for_kind is derived from the kind gate, not a second list" do
    for kind <- Site.kinds() do
      shipped = Site.shipped_frameworks_for_kind(kind)
      assert shipped -- Site.frameworks_for_kind(kind) == []
      assert shipped -- Site.shipped_frameworks() == []
      # Every kind must keep at least one creatable framework: a kind whose menu
      # is empty is a kind nobody can use, and the 422 would name nothing.
      assert shipped != [], "kind #{kind} has no creatable framework left"
    end

    assert Site.shipped_frameworks_for_kind("static") == ~w(astro static)
    assert Site.shipped_frameworks_for_kind("container") == ~w(nextjs)
    assert Site.shipped_frameworks_for_kind("node") == ~w(nextjs)
  end
end
