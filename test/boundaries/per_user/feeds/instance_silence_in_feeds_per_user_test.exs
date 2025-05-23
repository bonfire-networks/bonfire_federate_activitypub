defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceFeedsPerUserTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://mocked.local/users/karen"
  @local_actor "alice"

  setup_all do
    # TODO: move this into fixtures
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  # test "shows in fediverse feed an incoming Note with no per-user silencing" do
  #   local_user = fake_user!(@local_actor)
  #   {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])
  #   |> debug("ppppooost")

  #   # |> debug()
  #   assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, local_user)
  # end

  test "does not show in my_feed an incoming Note from a per-user silenced instance (from an actor I am not following)" do
    local_user = fake_user!(@local_actor)

    assert {:ok, instance} = Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug

    assert Bonfire.Boundaries.Blocks.block(instance, :silence, current_user: local_user)

    assert Bonfire.Federate.ActivityPub.Instances.instance_blocked?(instance, :silence,
             current_user: local_user
           )

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    refute Bonfire.Social.FeedLoader.feed_contains?(:my, post, local_user)
  end

  test "does not show in my_feed an incoming Note from a per-user silenced instance (from an actor that I am already following)" do
    local_user = fake_user!(@local_actor)

    {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    assert {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

    Bonfire.Social.Graph.Follows.follow(local_user, remote_user)

    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    ~> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    refute Bonfire.Social.FeedLoader.feed_contains?(:my, post, local_user)
  end

  test "hides a Post in feeds from a remote instance that was per-user silenced later" do
    local_user = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    assert {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

    assert {:ok, instance} =
             Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
             |> debug("inssstance")

    assert Bonfire.Boundaries.Circles.is_encircled_by?(remote_user, instance)

    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, local_user)

    assert Bonfire.Boundaries.Blocks.block(instance, :silence, current_user: local_user)

    assert Bonfire.Federate.ActivityPub.Instances.instance_blocked?(instance, :silence,
             current_user: local_user
           )

    assert Bonfire.Federate.ActivityPub.Peered.actor_blocked?(remote_user, :silence,
             current_user: local_user
           )

    # refute Bonfire.Boundaries.can?(local_user, :read, post) 

    # assert Bonfire.Boundaries.Blocks.is_blocked?(remote_user, :silence,
    #          current_user: local_user
    #        ) 

    refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, local_user)

    # we show it once again
    assert Bonfire.Boundaries.Blocks.unblock(instance, :silence, current_user: local_user)
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, local_user)
  end

  test "does not show in any feeds a Post for an incoming Note from a previously per-user silenced instance" do
    local_user = fake_user!(@local_actor)

    assert {:ok, instance} = Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug

    assert Bonfire.Boundaries.Blocks.block(instance, :silence, current_user: local_user)

    assert Bonfire.Federate.ActivityPub.Instances.instance_blocked?(instance, :silence,
             current_user: local_user
           )

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    refute Bonfire.Social.FeedLoader.feed_contains?(:remote, post, local_user)
  end
end
