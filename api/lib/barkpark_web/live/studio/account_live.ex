defmodule BarkparkWeb.Studio.AccountLive do
  @moduledoc """
  **Your data** — the signed-in user's GDPR self-service page in Studio
  (era-bl-gdpr-selfserve-ui). Two sections:

    1. **Download your data** — a plain link to `GET /v1/auth/export`. The
       browser sends the `user_session` cookie, `RequireUserSession` resolves
       the subject exactly as it does for every other caller, and the
       `download` attribute saves the JSON as `barkpark-data-export.json`.
       The filename is the same for every user and carries no email or id, so
       it reveals nothing about whose file it is. The page adds no second
       export path.

    2. **Erase your account** — pseudonymising erasure through
       `Barkpark.Accounts.Privacy.erase_subject/1`, called in-process. The HTTP
       door (`POST /v1/auth/erase`) is not usable from a Studio form: its cookie
       branch demands an `x-requested-with` header that a form cannot send, so
       reaching it would need a JavaScript fetch the LiveView tests cannot
       drive. The handler therefore runs the same checks that door runs, with
       the same functions: the subject is the user the `user_session` cookie
       resolves to (`Accounts.verify_user_session/1`, re-run at submit so a
       session revoked since mount is refused), the password is checked with
       `User.valid_password?/2` against the freshly loaded row, and only then
       is `Privacy.erase_subject/1` called. Wrong-password attempts share a
       small per-user budget so the form cannot be used to guess passwords
       faster than the metered HTTP door allows.

  ## Who sees what

    * A signed-in account (`:current_user`) gets both sections.
    * A token-only session (an API token pasted at `/login`, no account) gets
      neither: a token is not a data subject — it has no email, password or
      memberships of its own to export or erase. The page says so in one line
      and links to account sign-in.
    * An anonymous visitor is asked to sign in.

  ## Secrets

  The password is read from the submit params, checked, and dropped. It is
  never assigned, never rendered back (the input's `value` is always empty and
  its DOM id changes on every attempt so the browser drops what was typed), and
  never logged by this module. Error messages name what happened and never
  echo the input.
  """

  use BarkparkWeb, :live_view

  import BarkparkWeb.Studio.PageScroll
  import BarkparkWeb.StudioComponents.Controls

  alias Barkpark.Accounts
  alias Barkpark.Accounts.Privacy
  alias Barkpark.Accounts.User
  alias Barkpark.RateLimiter

  @export_path "/v1/auth/export"
  @export_filename "barkpark-data-export.json"

  # Five password attempts, refilled at one a minute, per user.
  @reauth_capacity 5
  @reauth_refill_per_sec 1 / 60

  @doc "The fixed download filename. Carries no email, id or date."
  def export_filename, do: @export_filename

  @impl true
  def mount(_params, session, socket) do
    user_session_raw =
      case session["user_session"] do
        raw when is_binary(raw) and raw != "" -> String.trim(raw)
        _ -> nil
      end

    {:ok,
     assign(socket,
       page_title: "Your data",
       export_path: @export_path,
       export_filename: @export_filename,
       # The raw cookie value, kept server-side only (never rendered) so the
       # erase handler can re-verify the session at submit time — the same
       # posture as LiveAuth's `:api_token_raw`.
       user_session_raw: user_session_raw,
       acknowledged?: false,
       erase_error: nil,
       attempt: 0,
       erased?: false
     )}
  end

  @impl true
  def handle_event("erase", _params, %{assigns: %{erased?: true}} = socket) do
    # A second submit that raced the redirect. The account is already erased;
    # do nothing rather than erase (and audit) twice.
    {:noreply, socket}
  end

  def handle_event("erase", params, socket) do
    acknowledged? = params["acknowledge"] == "true"
    password = params["password"]

    socket = assign(socket, acknowledged?: acknowledged?, attempt: socket.assigns.attempt + 1)

    cond do
      not match?(%User{}, socket.assigns[:current_user]) ->
        {:noreply, assign(socket, erase_error: "Sign in with your account to erase it.")}

      not acknowledged? ->
        {:noreply,
         assign(socket,
           erase_error:
             "Tick the box to confirm you understand what erasure does. Nothing was erased."
         )}

      not is_binary(password) or password == "" ->
        {:noreply,
         assign(socket,
           erase_error: "Enter your current password to erase your account. Nothing was erased."
         )}

      true ->
        erase_with_password(socket, password)
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp erase_with_password(socket, password) do
    with {:session, {%User{} = user, _session}} <- {:session, live_session(socket)},
         {:budget, :ok} <- {:budget, reauth_budget(user)},
         {:password, true} <- {:password, User.valid_password?(user, password)},
         {:erase, {:ok, _summary}} <- {:erase, Privacy.erase_subject(user)} do
      {:noreply,
       socket
       |> assign(erased?: true, erase_error: nil)
       |> put_flash(
         :info,
         "Your account was erased. Every session was signed out, so sign-in is required again."
       )
       |> redirect(to: "/login")}
    else
      {:session, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your session has ended. Sign in again to continue.")
         |> redirect(to: "/login")}

      {:budget, :rate_limited} ->
        {:noreply,
         assign(socket,
           erase_error:
             "Too many password attempts. Wait a minute and try again. Nothing was erased."
         )}

      {:password, false} ->
        {:noreply,
         assign(socket,
           erase_error: "That password is not correct. Nothing was erased."
         )}

      {:erase, _error} ->
        {:noreply,
         assign(socket,
           erase_error: "Erasure failed and nothing was changed. Try again in a moment."
         )}
    end
  end

  defp live_session(%{assigns: %{user_session_raw: raw}}) when is_binary(raw),
    do: Accounts.verify_user_session(raw)

  defp live_session(_socket), do: nil

  # `scoped_key/2` is the identity outside tests; a LiveView socket carries no
  # test scope, so the key is per-user either way (the census in
  # rate_limiter_scoped_key_coverage_test.exs requires the call shape).
  defp reauth_budget(%User{id: id}) do
    RateLimiter.check(RateLimiter.scoped_key(nil, {:studio_erase_reauth, id}),
      capacity: @reauth_capacity,
      refill_per_sec: @reauth_refill_per_sec
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.studio_page_scroll>
      <div
        class="account-live"
        style="max-width: 720px; margin: 32px auto; padding: 0 24px; font-family: var(--font);"
      >
        <h1 class="h1" style="margin-bottom: 4px;">Your data</h1>

        <%= cond do %>
          <% match?(%User{}, @current_user) -> %>
            <p style="color: var(--fg-muted); margin-top: 0;">
              Download or erase the personal data Barkpark holds for
              <strong data-test-id="account-email">{@current_user.email}</strong>.
            </p>
            {render_export_section(assigns)}
            {render_erase_section(assigns)}
          <% @api_token -> %>
            <p role="status" data-test-id="account-token-only" style="color: var(--fg-muted);">
              You are signed in with an API token, which is not an account, so there is no
              personal data to download or erase. <a href="/login">Sign in with your account</a>
              to manage your data.
            </p>
          <% true -> %>
            <p role="status" data-test-id="account-signed-out" style="color: var(--fg-muted);">
              <a href="/login">Sign in with your account</a> to download or erase your data.
            </p>
        <% end %>
      </div>
    </.studio_page_scroll>
    """
  end

  defp render_export_section(assigns) do
    ~H"""
    <.bp_card aria-labelledby="export-heading">
      <.bp_section_header id="export-heading" title="Download your data">
        A JSON file with your account details, sign-in sessions, pending email links,
        workspace memberships and the audit events you performed. It contains no password,
        session token or two-factor secret.
      </.bp_section_header>

      <a
        href={@export_path}
        download={@export_filename}
        class="btn btn-primary"
        data-test-id="account-export"
      >
        Download my data
      </a>
    </.bp_card>
    """
  end

  defp render_erase_section(assigns) do
    ~H"""
    <.bp_card aria-labelledby="erase-heading">
      <.bp_section_header id="erase-heading" title="Erase your account">
        Erasure cannot be undone. Download your data first if you want a copy.
      </.bp_section_header>

      <ul data-test-id="erase-consequences" style="margin: 0 0 16px; padding-left: 20px; color: var(--fg);">
        <li>Your email address is replaced with an anonymous placeholder, and your password, two-factor secret and recovery codes are deleted.</li>
        <li>Every sign-in session is revoked, on every device, including this one. You are signed out immediately.</li>
        <li>Pending email links stop working and you are removed from every workspace.</li>
        <li>
          Personal access tokens you own are revoked, and your passkeys and social sign-in links
          are removed.
        </li>
        <li>
          Machine tokens you created as a workspace admin stay with that workspace.
        </li>
        <li>
          Your account is pseudonymised, not deleted: the audit log keeps its records of what this
          account did, attributed to the anonymous placeholder.
        </li>
      </ul>

      <form id="erase-form" phx-submit="erase">
        <div style="margin-bottom: 16px;">
          <.bp_checkbox
            id="erase-acknowledge"
            name="acknowledge"
            value="true"
            checked={@acknowledged?}
            label="I understand that erasing my account cannot be undone."
          />
        </div>

        <.bp_field_row label="Current password" for={"erase-password-#{@attempt}"} required>
          <.bp_input
            id={"erase-password-#{@attempt}"}
            name="password"
            type="password"
            value=""
            autocomplete="current-password"
          />
        </.bp_field_row>

        <p
          :if={@erase_error}
          role="alert"
          data-test-id="erase-error"
          style="color: var(--destructive); margin: 0 0 12px;"
        >
          {@erase_error}
        </p>

        <button
          type="submit"
          class="btn btn-destructive"
          phx-disable-with="Erasing…"
          disabled={@erased?}
        >
          Erase my account
        </button>
      </form>
    </.bp_card>
    """
  end
end
