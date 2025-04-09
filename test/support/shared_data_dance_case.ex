defmodule Bonfire.Federate.ActivityPub.SharedDataDanceCase do
  use ExUnit.CaseTemplate
  import Tesla.Mock
  import Untangle
  import Bonfire.UI.Common.Testing.Helpers
  alias Bonfire.Common.TestInstanceRepo

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest

      import Bonfire.UI.Common.Testing.Helpers

      import Phoenix.LiveViewTest
      # import Bonfire.Federate.ActivityPub.ConnCase
      import Bonfire.Federate.ActivityPub.Test.ConnHelpers

      use Bonfire.Common.Utils

      alias Bonfire.Federate.ActivityPub.Simulate
      alias Bonfire.Common.Config

      # The default endpoint for testing
      @endpoint Application.compile_env!(:bonfire, :endpoint_module)

      @moduletag :test_instance
    end
  end

  setup_all tags do
    info("Start with a DanceTest")

    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    on_exit(fn ->
      info("Done with a DanceTest")
      ActivityPub.Utils.cache_clear()

      # this callback needs to checkout its own connection since it
      # runs in its own process
      # :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
      # Ecto.Adapters.SQL.Sandbox.mode(repo(), :auto)

      # Object.delete(actor1)
      # Object.delete(actor2)
      :ok
    end)

    ActivityPub.Utils.cache_clear()

    Bonfire.Common.Repo.config()
    |> Keyword.take([:name, :database, :hostname, :port, :username])
    |> debug("LOCAL DB CONFIG")

    TestInstanceRepo.config()
    |> Keyword.take([:name, :database, :hostname, :port, :username])
    |> debug("REMOTE DB CONFIG")

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()

      if !Bonfire.Boundaries.Circles.exists?(Bonfire.Boundaries.Circles.get_id!(:local)) do
        info("Seems boundary fixtures are missing on test instance, running now")
        Bonfire.Boundaries.Scaffold.insert()
      end
    end)

    [
      local: fancy_fake_user!("Local"),
      remote: fancy_fake_user_on_test_instance()
    ]
  end
end
