defmodule Bonfire.Federate.ActivityPub.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MyApp.Web.ChannelCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import Bonfire.Federate.ActivityPub.ChannelCase

      alias Bonfire.Federate.ActivityPub.Simulate

      # The default endpoint for testing
      @endpoint Application.compile_env!(:bonfire, :endpoint_module)

      @moduletag :federation
    end
  end

  setup tags do
    # import Bonfire.Common.Config, only: [repo: 0]

    ActivityPub.Utils.cache_clear()

    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    :ok
  end
end
