defmodule Bonfire.Federate.ActivityPub.Boundaries.InstanceSilenceFeedsInstanceWideTest do
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

  test "does not accept an incoming Note from a silenced instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

    recipient = fake_user!(@local_actor)
    assert {:error, _} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])
    # refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, recipient)
  end

  test "hides a Post in feeds from a remote instance that was silenced later" do
    recipient = fake_user!(@local_actor)
    bob = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])

    {:ok, instance} = Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    Bonfire.Boundaries.Blocks.block(instance, :silence, :instance_wide)

    assert Bonfire.Federate.ActivityPub.Instances.instance_blocked?(
             instance,
             :silence,
             :instance_wide
           )

    refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, recipient)
    refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, bob)
    refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post)

    # we show it once again
    assert Bonfire.Boundaries.Blocks.unblock(instance, :silence, :instance_wide)
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, recipient)
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, bob)
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post)
  end
end
