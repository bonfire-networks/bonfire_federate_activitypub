defmodule Bonfire.Federate.ActivityPub.PostsHashtagsLiveTest do
  @moduledoc """
  A public post with hashtags (`Testing.Scenarios.posts_hashtags/3`), between us and a real server's account (`{Tester.NomadTester, {:mastodon_api, server}}`, one for each `.env` server), both ways: our post found and shown through its Mastodon API, and its post, made through that API, found and shown here. The dance's other instance and Fedify run the same scenario in `dance/posts_hashtags_test.exs`.

  Each server fetches what the other posted through the tunnel, so it runs through the recipe that tunnels both dance instances:

      just test-federation-live-dance-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/posts_hashtags_live_test.exs

  The accounts are the `.env` ones of `proofs_live_test.exs`; a server whose two variables are not set is skipped.

  ⚠️ It acts as a real person: the account posts a public test post, which stays on that server.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  # not `:test_instance`: it reaches real servers, so it runs through the live recipe only
  @moduletag :live_federation

  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  for server <- ~w(mitra mastodon),
      {sender, receiver, direction} <- [
        {{Tester.NomadTester, :local}, {Tester.NomadTester, {:mastodon_api, server}},
         "us to #{server}"},
        {{Tester.NomadTester, {:mastodon_api, server}}, {Tester.NomadTester, :local},
         "#{server} to us"}
      ] do
    @tag server: server
    @tag sender: sender, receiver: receiver
    @tag timeout: :timer.minutes(5)
    @tag skip:
           MastodonApi.from_env(server) == nil &&
             "set LIVE_TEST_#{String.upcase(server)}_URL and LIVE_TEST_#{String.upcase(server)}_TOKEN in .env"
    test "#{direction}: finds a public post, and shows its text and hashtags", context do
      Scenarios.posts_hashtags(
        context,
        Tester.new(context[:sender], context),
        Tester.new(context[:receiver], context)
      )
    end
  end
end
