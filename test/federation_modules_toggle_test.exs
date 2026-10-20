defmodule Bonfire.Federate.ActivityPub.FederationModulesToggleTest do
  @moduledoc """
  A federation module of an extension that is enabled and disabled at runtime is found again as soon as the extension is enabled, with no cache to clear in between.

  `federation_module/1` reads the map `FederationModules.federation_modules_data_types/0` builds through `ExtensionBehaviour.apply_modules_cached/2`. It does not check enablement itself: the callers do, and outgoing federation answers a disabled module with its own "was disabled" error, which needs the module back.
  """
  use ExUnit.Case, async: false

  # bucket this into the backend CI leg: bare `ExUnit.Case` skips the tag that `Bonfire.Common.DataCase` applies
  @moduletag :backend

  alias Bonfire.Common.Testing
  alias Bonfire.Federate.ActivityPub.FederationModules

  # `bonfire_social` is enabled in every flavour, and `Flags` declares this verb and type
  @extension :bonfire_social
  @query {"Create", "Flag"}

  test "a federation module of a toggled extension is found once the extension is enabled again" do
    # fills the cache while disabled; what it returns during is not asserted, as callers check enablement
    Testing.with_extension_disabled(@extension, fn ->
      FederationModules.federation_module(@query)
    end)

    assert {:ok, Bonfire.Social.Flags} = FederationModules.federation_module(@query)
  end
end
