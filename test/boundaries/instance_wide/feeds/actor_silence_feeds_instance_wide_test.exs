defmodule Bonfire.Federate.ActivityPub.Boundaries.ActorSilenceFeedsInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://mocked.local/users/karen"

  @local_actor "alice"

  setup_all do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      silence_them: [],
      ghost_them: []
    )

    # TODO: move this into fixtures
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end

  # test "show in feeds an incoming Note with no silencing" do
  #   recipient = fake_user!(@local_actor)
  #   {:ok, post} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])

  #   assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, recipient)
  # end

  test "does not accept an incoming Note with silenced actor" do
    {:ok, remote_user} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
    Bonfire.Boundaries.Blocks.block(user, :silence, :instance_wide)

    recipient = fake_user!(@local_actor)
    assert {:error, _} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])
    # refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, recipient)
  end
end
