defmodule BarkparkWeb.Studio.ChatHostsLive.HostCard do
  @moduledoc """
  One machine on the Chat hosts page (/papers/chat-host-enrollment-overhaul
  T4): its state in words, its folders, what it can run, and the actions that
  state allows. A waiting machine shows the command to run while this page
  still holds the code it made; otherwise it offers a new code, which replaces
  the old one.
  """
  use Phoenix.Component

  @online_window 90

  @doc """
  The state a person reads, from the public host map and the current time:
  `{:waiting, seconds_left}`, `:expired`, `:online` or `{:offline, seen_at}`.
  """
  def state(%{enrolled: false} = host, now) do
    case host[:enrollment_expires_at] do
      %DateTime{} = at ->
        left = DateTime.diff(at, now)
        if left > 0, do: {:waiting, left}, else: :expired

      _ ->
        :expired
    end
  end

  def state(%{online: true}, _now), do: :online
  def state(host, _now), do: {:offline, host[:last_seen_at]}

  @doc "The readable provider lines: \"Claude: signed in · 2.1.328\"."
  def capability_lines(capabilities) when is_map(capabilities) do
    capabilities
    |> Map.get("providers", %{})
    |> case do
      providers when is_map(providers) -> providers
      _ -> %{}
    end
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, readiness} -> {provider_label(name), readiness_text(readiness)} end)
  end

  def capability_lines(_), do: []

  defp provider_label(name) when is_binary(name), do: String.capitalize(name)
  defp provider_label(name), do: to_string(name)

  defp readiness_text(%{"installed" => true} = r) do
    signed = if r["auth_ready"] == true, do: "signed in", else: "installed, not signed in"
    Enum.join(Enum.reject([signed, r["version"]], &(&1 in [nil, ""])), " · ")
  end

  defp readiness_text(_), do: "not installed"

  @doc "\"7 min\", \"under a minute\", \"3 h\", \"2 days\"."
  def rough(seconds) when seconds < 60, do: "under a minute"
  def rough(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"
  def rough(seconds) when seconds < 172_800, do: "#{div(seconds, 3600)} h"
  def rough(seconds), do: "#{div(seconds, 86_400)} days"

  def ago(nil, _now), do: "never"
  def ago(%DateTime{} = at, now), do: rough(max(DateTime.diff(now, at), 0)) <> " ago"

  def online_window, do: @online_window

  attr :host, :map, required: true
  attr :now, :any, required: true
  attr :code, :string, default: nil
  attr :command, :string, default: nil
  attr :can_enroll, :boolean, default: false

  def card(assigns) do
    assigns = assign(assigns, :state, state(assigns.host, assigns.now))

    ~H"""
    <article class={["ch-host", "ch-host--#{state_key(@state)}"]} data-host-state={state_key(@state)} id={"chat-host-#{@host.id}"}>
      <div class="ch-host-head">
        <span class="ch-dot" aria-hidden="true"></span>
        <h3 class="ch-host-name">{@host.name}</h3>
        <span class="ch-pill">{state_label(@state)}</span>
      </div>

      <p class="ch-host-meta">
        <span :for={root <- @host.approved_roots} class="ch-path">{root}</span>
        <span :if={match?({:offline, _}, @state)}>
          · last seen {ago(elem(@state, 1), @now)}
        </span>
      </p>

      <ul :if={@host.enrolled and capability_lines(@host.capabilities) != []} class="ch-caps">
        <li :for={{label, text} <- capability_lines(@host.capabilities)}>
          <strong>{label}</strong>
          {text}
        </li>
      </ul>

      <div :if={@code && match?({:waiting, _}, @state)} class="ch-code" data-copy-root>
        <p class="ch-code-lead">
          Run this on the machine. The code works once, for {rough(elem(@state, 1))} more, and goes in on
          stdin so it never shows in the machine's process list.
        </p>
        <%!-- phx-update="ignore" keeps "Copied" across the 5 s refresh. The
              id carries a hash of the code, so a new code is a new element
              and never shows a stale command. The copy handler is the CSP
              allow-listed one that copies the field just before the button,
              as-is (BarkparkWeb.CSP). --%>
        <div
          class="ch-command"
          id={"chat-host-command-box-#{@host.id}-#{:erlang.phash2(@code)}"}
          phx-update="ignore"
        >
          <textarea
            id={"chat-host-command-#{@host.id}"}
            readonly
            rows="3"
            spellcheck="false"
            aria-label={"Command to run on #{@host.name}"}
          >{@command}</textarea>
          <button
            type="button"
            class="btn btn-sm btn-primary"
            data-copied="Copied"
            onclick={BarkparkWeb.CSP.copy_previous_value_onclick()}
          >Copy</button>
        </div>
        <p class="ch-code-next">
          Then start it there and keep it running: <code>barkpark-chat-host run</code>. This card turns
          green when it connects.
        </p>
      </div>

      <p :if={is_nil(@code) and match?({:waiting, _}, @state)} class="ch-host-note">
        Waiting for the machine to enroll. The code was shown once, when it was made.
        <%= if @can_enroll do %>
          Lost it? Make a new code; the old one stops working.
        <% else %>
          If it was lost, ask the workspace owner for a new code.
        <% end %>
      </p>
      <p :if={@state == :expired} class="ch-host-note">
        The code expired before the machine enrolled.
        <%= if @can_enroll do %>
          Make a new code to try again.
        <% else %>
          Ask the workspace owner for a new code.
        <% end %>
      </p>
      <p :if={match?({:offline, _}, @state)} class="ch-host-note">
        Start it on the machine with <code>barkpark-chat-host run</code>.
      </p>

      <div class="ch-host-actions">
        <button
          :if={@can_enroll and not @host.enrolled}
          type="button"
          class="btn btn-sm"
          phx-click="new_code"
          phx-value-id={@host.id}
        >Make a new code</button>
        <button
          type="button"
          class="btn btn-sm btn-destructive"
          phx-click="ask_revoke"
          phx-value-id={@host.id}
        >{if @host.enrolled, do: "Revoke", else: "Remove"}</button>
      </div>
    </article>
    """
  end

  defp state_key({:waiting, _}), do: "waiting"
  defp state_key(:expired), do: "expired"
  defp state_key(:online), do: "online"
  defp state_key({:offline, _}), do: "offline"

  defp state_label({:waiting, left}), do: "Waiting · #{rough(left)} left"
  defp state_label(:expired), do: "Code expired"
  defp state_label(:online), do: "Online"
  defp state_label({:offline, _}), do: "Offline"
end
