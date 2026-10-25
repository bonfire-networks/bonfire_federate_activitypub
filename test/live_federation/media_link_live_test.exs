defmodule Bonfire.Federate.ActivityPub.MediaLinkLiveTest do
  @moduledoc """
  A post's image attachment, us to them (`Testing.Scenarios.alt_text/2`), run for a real server's account (`Tester.NomadTester`, one for each `.env` server): it shows the image with its alt text, through its Mastodon API. The dance's other instance and Fedify run the same scenario in `dance/media_link_dance_test.exs`.

  The real server fetches our post from the dance's instance, so it runs through the recipe that tunnels both:

      just test-federation-live-dance-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/media_link_live_test.exs

  The accounts are the `.env` ones of `proofs_live_test.exs`; a server whose two variables are not set is skipped.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  # not `:test_instance`: it reaches real servers, so it runs through the live recipe only
  @moduletag :live_federation

  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  for server <- ~w(mitra mastodon) do
    @tag server: server
    @tag timeout: :timer.minutes(5)
    @tag skip:
           MastodonApi.from_env(server) == nil &&
             "set LIVE_TEST_#{String.upcase(server)}_URL and LIVE_TEST_#{String.upcase(server)}_TOKEN in .env"
    test "#{server}: a post's image attachment keeps its alt text", context do
      Scenarios.alt_text(
        context,
        Tester.new({Tester.NomadTester, {:mastodon_api, context[:server]}}, context)
      )
    end
  end
end
