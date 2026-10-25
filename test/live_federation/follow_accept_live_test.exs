defmodule Bonfire.Federate.ActivityPub.LiveFederation.FollowAcceptLiveTest do
  @moduledoc """
  Live probe of the plainest possible round trip: follow a REAL remote actor and wait for its `Accept`.

  Exists to triangulate a group-federation failure: our Follow to a Lemmy community produced no Accept, but the send itself looked fine (the success path logs at `debug`, which is suppressed at the live run's level, so a successful POST is invisible). Following an ordinary Mastodon account, which auto-accepts unless locked, separates the two possibilities:

    * Accept arrives → our outgoing Follow and inbound Accept handling both work, so the Lemmy case is Lemmy-specific (their validation, or a Group-actor difference)
    * no Accept → the problem is ours and not group-related at all: either the Follow never really goes out, or we drop/ignore incoming Accepts

  Run (the tunnel is required so the remote can fetch our actor back):

      LIVE_TEST_ACTOR='@someone@mastodon.social' just test-federation-live-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/follow_accept_live_test.exs

  Use an account you control, and unfollow afterwards.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server and the remote fetching back run outside the test process
  @moduletag db_sandbox: false

  alias Bonfire.Federate.ActivityPub.Testing.Scenarios

  @actor_env "LIVE_TEST_ACTOR"

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp actor_handle! do
    System.get_env(@actor_env) ||
      flunk("""
      Set #{@actor_env} to a real remote actor you control, eg.
        #{@actor_env}='@you@mastodon.social'
      """)
  end

  # no Accept means the problem is ours and not group-related: our Follow never really went out, or we drop incoming Accepts
  test "a remote actor Accepts our Follow", context do
    Scenarios.follow_accepted(Map.put(context, :local, %{user: fake_user!()}), actor_handle!())
  end
end
