defmodule BarkparkWeb.Studio.LeaveScopeLocaleTest do
  @moduledoc """
  task-82f506e97f488de0: the three notices the leave question's gate shows
  (`LeaveScope`) are read in the caller's locale, at call time.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.LeaveScope

  test "under nb_NO the three notices are Norwegian" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert LeaveScope.notice() ==
               "Ikke lagret: siden er flyttet til et annet prosjekt. Velg Bli her eller Forlat først."

      assert LeaveScope.held_notice() ==
               "Ikke lastet inn på nytt: siden er flyttet til et annet prosjekt. Velg Bli her eller Forlat først."

      assert LeaveScope.held_opens_notice() ==
               "Ikke åpnet: siden er flyttet til et annet prosjekt. Velg Bli her eller Forlat først."
    end)
  end

  test "control: under en they are the English the gate showed before" do
    Gettext.with_locale(BarkparkWeb.Gettext, "en", fn ->
      assert LeaveScope.notice() ==
               "Not saved: the page has moved to another project. Choose Stay or Leave first."

      assert LeaveScope.held_notice() ==
               "Not reloaded: the page has moved to another project. Choose Stay or Leave first."

      assert LeaveScope.held_opens_notice() ==
               "Not opened: the page has moved to another project. Choose Stay or Leave first."
    end)
  end
end
