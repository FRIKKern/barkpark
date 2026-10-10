defmodule BarkparkWeb.StudioRefusalHTML do
  @moduledoc """
  The HTML page `BarkparkWeb.Plugs.ResolveWorkspace` renders for a signed-in
  browser request the Studio membership gate refuses (task-47ab98b3226672ef).

  Rendered through `Phoenix.Controller.render/3` (a `put_view` + template
  lookup, same shape `BarkparkWeb.ErrorHTML` uses for a plug-level page with
  no controller action behind it) rather than a direct
  `Phoenix.Controller.html/2` call: Sobelow's `XSS.HTML` check flags ANY
  non-literal body passed to that specific function regardless of escaping
  (see `RateLimit`'s own `@html_429` comment for the prior case of this),
  and the actual `send_resp` for a template render happens inside Phoenix's
  own compiled code, outside anything Sobelow scans in this app.

  The markup itself is a real `~H` (HEEx) template, not a hand-built string
  passed through `Phoenix.HTML.raw/1` — `error_html.ex`'s `page/2` does the
  latter and carries Sobelow's matching `XSS.Raw` finding uncounted on main
  (same blunt "is the `raw/1` argument a literal" check, same false
  positive: both interpolated values there come from the template name
  Phoenix passes in, never request input). `~H` auto-escapes every `{...}`
  interpolation at compile time and isn't a call to `raw/1` at all, so this
  file carries neither finding. Every interpolated value here is a static
  gettext string (translator-authored, never request input) or
  `StudioLocale.html_lang/0` (the locale the plug put on this process,
  restricted to `Tenancy.known_locales/0`) — nothing from the request
  itself (workspace slug, refusal reason) ever reaches this page, which is
  the point (no existence leak).

  Its palette is `design/tokens.json`'s `color.errorPage` — the same fixed-
  dark family `BarkparkWeb.ErrorHTML`'s 404/500 page uses, via the SAME
  generated `:root` block (design/emit.mjs's `errorPageBlock/0`, now emitted
  into both files). Studio's literal-color gate
  (`scripts/studio-literal-check.sh`) bans a bare hex/hsl() outside that
  block; there is no bespoke accent here for exactly that reason — both
  buttons are styled from `--err-bg`/`--err-fg`/`--err-muted` alone.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.StudioLocale

  # A pending invitation to the workspace the caller tried to open
  # (task-5306379c9be40c89). Only the INVITED user is shown it; a caller with
  # no invitation there gets the exact page below either way, so the page still
  # says nothing about whether that workspace exists.
  def render("refusal.html", assigns) do
    invitation = assigns[:invitation]

    assigns =
      Map.merge(assigns, %{
        lang: StudioLocale.html_lang(),
        # The tab title is read first; an invited caller's page is an invitation.
        title:
          if(invitation,
            do: gettext("Studio · Invitation"),
            else: gettext("Studio · Not a member")
          ),
        heading:
          if(invitation,
            do: gettext("You're invited to %{workspace}", workspace: invitation_name(invitation)),
            else: gettext("You're not a member of this workspace")
          ),
        body:
          if(invitation,
            do:
              gettext(
                "Someone invited this account to join as %{role}. Accept to open the workspace, or decline the invitation.",
                role: role_word(invitation.role)
              ),
            else:
              gettext(
                "You're signed in, but this account doesn't have access here. Go to one of your own workspaces, or sign in as someone else."
              )
          ),
        invitation: invitation,
        csrf_token: assigns[:csrf_token],
        go_home: gettext("Go to your workspace"),
        sign_in_other: gettext("Sign in as someone else"),
        see_invitations: gettext("Your invitations"),
        accept: gettext("Accept invitation"),
        decline: gettext("Decline")
      })

    ~H"""
    <.page lang={@lang} title={@title}>
      <h1>{@heading}</h1>
      <p>
        {@body}
      </p>
      <div :if={@invitation} class="actions">
        <form method="post" action={"/invitations/#{@invitation.id}/accept"}>
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <button type="submit" class="btn btn-primary">{@accept}</button>
        </form>
        <form method="post" action={"/invitations/#{@invitation.id}/decline"}>
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <button type="submit" class="btn btn-secondary">{@decline}</button>
        </form>
      </div>
      <div class="actions">
        <a class={["btn", if(@invitation, do: "btn-secondary", else: "btn-primary")]} href="/">
          {@go_home}
        </a>
        <a class="btn btn-secondary" href="/login">{@sign_in_other}</a>
      </div>
      <p class="more"><a href="/invitations">{@see_invitations}</a></p>
    </.page>
    """
  end

  # The signed-in user's pending invitations, one row each with Accept and
  # Decline (`BarkparkWeb.InvitationPageController`).
  def render("invitations.html", assigns) do
    assigns =
      Map.merge(assigns, %{
        lang: StudioLocale.html_lang(),
        declined:
          assigns[:declined] &&
            gettext("You declined the invitation to %{workspace}.",
              workspace: assigns[:declined]
            ),
        heading: gettext("Your invitations"),
        none: gettext("You have no pending invitations."),
        error: assigns[:error] && gettext("That invitation is no longer open."),
        go_home: gettext("Go to your workspace"),
        accept: gettext("Accept invitation"),
        decline: gettext("Decline")
      })

    # A decline's result leads the title too: the title is what a screen
    # reader reads first when the page comes back.
    assigns =
      Map.put(
        assigns,
        :title,
        if(assigns.declined,
          do: gettext("Invitation declined") <> " · " <> gettext("Studio · Invitations"),
          else: gettext("Studio · Invitations")
        )
      )

    ~H"""
    <.page lang={@lang} title={@title}>
      <h1>{@heading}</h1>
      <p :if={@declined} class="notice">{@declined}</p>
      <p :if={@error} role="alert">{@error}</p>
      <p :if={@invitations == []}>{@none}</p>
      <ul :if={@invitations != []} class="invites">
        <li :for={i <- @invitations}>
          <span class="invite-name">{invitation_name(i)}</span>
          <span class="invite-role">{role_word(i.role)}</span>
          <span class="actions">
            <form method="post" action={"/invitations/#{i.id}/accept"}>
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <button
                type="submit"
                class="btn btn-primary"
                aria-label={gettext("Accept the invitation to %{workspace}", workspace: invitation_name(i))}
              >
                {@accept}
              </button>
            </form>
            <form method="post" action={"/invitations/#{i.id}/decline"}>
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <button
                type="submit"
                class="btn btn-secondary"
                aria-label={gettext("Decline the invitation to %{workspace}", workspace: invitation_name(i))}
              >
                {@decline}
              </button>
            </form>
          </span>
        </li>
      </ul>
      <div class="actions">
        <a class="btn btn-secondary" href="/">{@go_home}</a>
      </div>
    </.page>
    """
  end

  # The built-in seat roles by a word; a workspace's own custom role name is
  # its data and is shown as written.
  defp role_word("owner"), do: pgettext("workspace role", "owner")
  defp role_word("admin"), do: pgettext("workspace role", "admin")
  defp role_word("member"), do: pgettext("workspace role", "member")
  defp role_word(role), do: role

  @doc "The name an invitation's workspace is shown by: its name, else its slug."
  def invitation_name(%{workspace_name: name}) when is_binary(name) and name != "", do: name
  def invitation_name(%{workspace: slug}), do: slug

  attr(:lang, :string, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={@lang}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
        <style>
          /* INTENTIONALLY ALWAYS-DARK (a stark error card, no theme switch).
             De-literalized onto design/tokens.json (color.errorPage) via the
             page-scoped FIXED-DARK block below — regenerate with
             `node design/emit.mjs --write`, never hand-edit. Shared verbatim
             with error_html.ex's own block (same family, same builder). */
          /* BEGIN GENERATED: tokens (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) */
          :root {
            --err-bg: #0f1115;
            --err-fg: #e6e6e6;
            --err-muted: #9aa0a6;
          }
          /* END GENERATED: tokens */
          body {
            font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
            background: var(--err-bg);
            color: var(--err-fg);
            display: flex;
            min-height: 100vh;
            margin: 0;
            align-items: center;
            justify-content: center;
          }
          main { text-align: center; padding: 2rem; max-width: 28rem; }
          h1 { font-size: 1.75rem; margin: 0 0 0.75rem; font-weight: 700; letter-spacing: -0.01em; }
          p { color: var(--err-muted); margin: 0 0 1.5rem; line-height: 1.5; }
          p.more a { color: var(--err-fg); }
          .actions { display: flex; gap: 0.75rem; justify-content: center; flex-wrap: wrap; margin-bottom: 1rem; }
          .actions form { margin: 0; }
          a.btn, button.btn {
            display: inline-block;
            padding: 0.5rem 1rem;
            border-radius: 0.375rem;
            text-decoration: none;
            font: inherit;
            font-weight: 600;
            border: 1px solid var(--err-muted);
            cursor: pointer;
          }
          .btn-primary { background: var(--err-fg); color: var(--err-bg); border-color: var(--err-fg); }
          .btn-secondary { background: transparent; color: var(--err-fg); }
          ul.invites { list-style: none; padding: 0; margin: 0 0 1.5rem; text-align: left; }
          ul.invites li { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem 0.75rem; padding: 0.75rem 0; border-bottom: 1px solid var(--err-muted); }
          .invite-name { font-weight: 600; flex: 1 1 10rem; }
          .invite-role { color: var(--err-muted); }
          ul.invites .actions { margin: 0; }
        </style>
      </head>
      <body>
        <main>
          {render_slot(@inner_block)}
        </main>
      </body>
    </html>
    """
  end
end
