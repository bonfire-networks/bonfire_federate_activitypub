defmodule Bonfire.Federate.ActivityPub.InboxForwardingLiveTest do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2) with three servers (`Testing.Scenarios.inbox_forwarding/2`), the follower being a real server's account (`Tester.NomadTester`, one for each `.env` server): it follows our user, a user on the dance's other instance replies to our user's post, and we forward the reply to the real server, which shows it under the post (the post's context, through its Mastodon API). Fedify runs the same scenario in `dance/inbox_forwarding_fedify_dance_test.exs`.

  The forward carries the replier's FEP-8b32 proof and our user's HTTP signature, so a server that shows the reply relied on the proof: the HTTP signer is not the reply's author. Mastodon reads such a proof (`actor_from_verified_object_integrity_proof`), and so does Mitra.

  Both dance instances must be reachable from the real server (it fetches the replier's key from the other instance), so it runs through the recipe that tunnels both:

      just test-federation-live-dance-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/inbox_forwarding_live_test.exs

  The accounts are the `.env` ones of `proofs_live_test.exs`; a server whose two variables are not set is skipped. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits.

  ⚠️ It acts as a real person: the account follows a test user here, and unfollows when the test ends.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  # not `:test_instance`: it acts as real people, so it runs through the live recipe only, never in `--only test_instance` dance runs
  @moduletag :live_federation
  @moduletag capture_log: false

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi
  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  setup context do
    Process.put(:federating, true)
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)

    clean_slate(context)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:activity_pub, :sign_object_integrity_proofs),
        else: Application.put_env(:activity_pub, :sign_object_integrity_proofs, orig)
    end)
  end

  # the servers that verify FEP-8b32 proofs and have a Mastodon-compatible API to read back what they did
  for server <- ~w(mitra mastodon) do
    @tag server: server
    @tag skip:
           MastodonApi.from_env(server) == nil &&
             "set LIVE_TEST_#{String.upcase(server)}_URL and LIVE_TEST_#{String.upcase(server)}_TOKEN in .env"
    @tag timeout: :timer.minutes(40)
    test "#{server}: a reply from the other instance to our user's post is forwarded to #{server}, which shows it under the post",
         context do
      Scenarios.inbox_forwarding(
        context,
        Tester.new({Tester.NomadTester, {:mastodon_api, context[:server]}}, context)
      )
    end
  end
end
