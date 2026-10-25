defmodule Bonfire.Federate.ActivityPub.DeliveryLiveTest do
  @moduledoc """
  A post delivered to a follower, us to them (`Testing.Scenarios.delivery/2`), the follower being a real server's account (`Tester.NomadTester`, one for each `.env` server): it follows our user, our user posts, and the post shows in its home timeline. The dance's other instance and Fedify run the same scenario in `dance/delivery_test.exs`.

  The real server fetches our user and receives our post through the tunnel, so it runs through the recipe that tunnels both dance instances:

      just test-federation-live-dance-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/delivery_live_test.exs

  The accounts are the `.env` ones of `proofs_live_test.exs`; a server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits.

  ⚠️ It acts as a real person: the account follows a test user here, and unfollows when the test ends.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  # not `:test_instance`: it acts as real people, so it runs through the live recipe only
  @moduletag :live_federation
  @moduletag capture_log: false

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  setup context do
    Process.put(:federating, true)
    clean_slate(context)
  end

  for server <- ~w(mitra mastodon) do
    @tag server: server
    @tag skip:
           MastodonApi.from_env(server) == nil &&
             "set LIVE_TEST_#{String.upcase(server)}_URL and LIVE_TEST_#{String.upcase(server)}_TOKEN in .env"
    @tag timeout: :timer.minutes(30)
    test "#{server}: a post delivered to a follower shows in its home timeline", context do
      Scenarios.delivery(
        context,
        Tester.new({Tester.NomadTester, {:mastodon_api, context[:server]}}, context)
      )
    end
  end
end
