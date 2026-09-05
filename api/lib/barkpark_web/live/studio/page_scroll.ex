defmodule BarkparkWeb.Studio.PageScroll do
  @moduledoc """
  The `.studio-shell` CHILD CONTRACT, as one reusable wrapper.

  `.studio-shell` (root.html.heex) is `display:flex; flex-direction:column;
  height:100vh; overflow:hidden`. The topbar sits above and the build-version
  footer below, and the LiveView root is the flex item between them. Because
  the shell clips and never scrolls, that root MUST either fill the remaining
  height and own its scroll, or delegate to something that does — otherwise
  everything past the fold is not merely awkward, it is UNREACHABLE: no input
  can move the viewport, so a toggle below the fold is a toggle that does not
  work.

  Panes that honour the contract already exist — `.pane-layout` (`flex: 1`),
  `.bp-page` (`flex: 1 1 auto; min-height: 0`), `.pane-body`, `.editor-body`.
  What did NOT exist was a wrapper for the OTHER shape the Studio uses: a
  document-like page that wants a centred, max-width reading column. Five such
  pages (settings, styleguide, connectors, org-admin, chat-hosts) each rendered
  that column straight into the shell and were clipped.

  This component is that missing shape. It fills the shell and owns the scroll;
  the caller's centred column rides INSIDE it, unchanged, so the reading measure
  is untouched.

  The rule is inline rather than a class because the Studio stylesheet lives in
  `root.html.heex`, a single hotly-contended file — the whole point of this
  wrapper is that a page can honour the contract without editing it.
  """

  use BarkparkWeb, :html

  @doc """
  A shell-filling, scrolling wrapper for a Studio page.

  Put the page's centred max-width column inside it:

      <.studio_page_scroll>
        <div class="settings-live" style="max-width: 720px; margin: 32px auto;">
          ...
        </div>
      </.studio_page_scroll>

  `min-height: 0` is load-bearing: a flex item's default `min-height: auto`
  refuses to shrink below its content, which would push the scroll back up to
  the clipping shell and reproduce the bug.
  """
  # @canonical capability:studio-shell-page-scroller aka:studio-shell,unreachable,below the fold,overflow hidden,100vh,scroll clipped
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def studio_page_scroll(assigns) do
    ~H"""
    <div
      class={["studio-page-scroll", @class]}
      style="flex: 1 1 auto; min-height: 0; overflow-y: auto;"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
