defmodule Barkpark.Capability.Supervisor do
  @moduledoc """
  Boot child for the capability-gated subsystems (see `Barkpark.Capability`).

  `Barkpark.Application` starts this supervisor unconditionally, in the slot
  `Barkpark.StudioChat.Supervisor` used to hold (after `Phoenix.PubSub`, before
  the Endpoint). It starts a subsystem's children only when that capability is
  enabled, so the application no longer names Studio Chat.

  Studio Chat contributes two children:

    * a start-only check that resolves `Barkpark.StudioChat.Titles.endpoint/0`
      once. A malformed `ANTHROPIC_API_URL` raises, which refuses the node
      before the Endpoint listens (the gh-9531 fail-closed contract that used
      to run inline in `Barkpark.Application.start/2`). It leaves no process.
    * `Barkpark.StudioChat.Supervisor`, the chat runtime tier.

  CycleFleet and EpicFleet are database ledgers with no processes, so they
  contribute no children. Their switch acts on their routes only
  (`BarkparkWeb.Plugs.RequireCapability`).
  """
  use Supervisor

  alias Barkpark.Capability

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  The child list, resolved against the CURRENT application env. Public so a
  test can assert the shape with a capability off and on without booting a
  second tree.
  """
  @spec children() :: [Supervisor.child_spec() | module()]
  def children do
    if Capability.enabled?(:studio_chat), do: studio_chat_children(), else: []
  end

  defp studio_chat_children do
    [
      %{
        id: :studio_chat_titles_endpoint_boot_check,
        start: {__MODULE__, :start_titles_endpoint_check, []},
        restart: :temporary
      },
      Barkpark.StudioChat.Supervisor
    ]
  end

  @doc """
  Resolves the Studio Chat title endpoint once. Returns `:ignore` on success so
  no process lingers; `Titles.endpoint/0` raises on a malformed value, and a
  raising child start takes this supervisor, and the boot, down.
  """
  @spec start_titles_endpoint_check() :: :ignore
  def start_titles_endpoint_check do
    _ = Barkpark.StudioChat.Titles.endpoint()
    :ignore
  end

  @impl true
  def init(:ok) do
    # Wider than the top supervisor's 3/5s budget, matching every other
    # intermediate tier, so a crash-loop below is contained here.
    Supervisor.init(children(), strategy: :one_for_one, max_restarts: 5, max_seconds: 10)
  end
end
