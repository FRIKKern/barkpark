defmodule BarkparkWeb.StudioChromeCreateRefusalLocaleTest do
  @moduledoc """
  task-b52ef8bc59eb1060 (part 2): the two workspace-create refusals the chrome
  and Studio share (`StudioChrome.refuse_unseated_create/1`,
  `refuse_suspended_create/1`) are read in the caller's locale, at call time.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.StudioChrome

  defp flash(fun) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    fun.(socket).assigns.flash["error"]
  end

  test "under nb_NO both refusals are Norwegian" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert flash(&StudioChrome.refuse_unseated_create/1) ==
               "Du trenger skrivetilgang i dette arbeidsområdet for å opprette et arbeidsområde"

      assert flash(&StudioChrome.refuse_suspended_create/1) ==
               "Dette arbeidsområdet er suspendert, så det kan ikke opprettes noe arbeidsområde herfra"
    end)
  end

  test "control: under en they are the English the refusals showed before" do
    Gettext.with_locale(BarkparkWeb.Gettext, "en", fn ->
      assert flash(&StudioChrome.refuse_unseated_create/1) ==
               "You need write access in this workspace to create a workspace"

      assert flash(&StudioChrome.refuse_suspended_create/1) ==
               "This workspace is suspended, so no workspace can be created from it"
    end)
  end
end
