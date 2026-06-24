defmodule Bonfire.Federate.ActivityPub.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MyApp.Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest

      import Bonfire.UI.Common.Testing.Helpers

      import PhoenixTest
      import Phoenix.LiveViewTest
      # import Bonfire.Federate.ActivityPub.ConnCase
      import Bonfire.Federate.ActivityPub.Test.ConnHelpers

      use Bonfire.Common.Utils

      import Bonfire.Federate.ActivityPub
      alias Bonfire.Federate.ActivityPub.Simulate
      use Bonfire.Common.Config

      # The default endpoint for testing
      @endpoint Application.compile_env!(:bonfire, :endpoint_module)

      @moduletag :federation
    end
  end

  setup tags do
    # import Bonfire.Common.Config, only: [repo: 0]

    ActivityPub.Utils.cache_clear()

    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    # Reset instance-wide federation mode to the open default before every federation test.
    # `federating`/`allowlist_only` are instance-scope settings persisted in Application env / DB
    # and are NOT rolled back by the Ecto sandbox, so a test that sets a restrictive mode (e.g.
    # allowlist-only) leaks it into later modules, rejecting all incoming activities.
    Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, false)
    Bonfire.Federate.ActivityPub.set_federating(:instance, true)

    {:ok, []}
  end
end
