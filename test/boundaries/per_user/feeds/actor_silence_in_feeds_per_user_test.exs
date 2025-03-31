defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceActorFeedsPerUserTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  import Bonfire.Boundaries.Debug
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

  test "incoming Notes with no per-user silencing show up in the fediverse feed" do
    local_user = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])
    # |> debug()
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, local_user)
  end

  test "does not show in my_feed an incoming Note from a per-user silenced actor that I am not following" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    assert {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

    Bonfire.Boundaries.Blocks.block(remote_user, :silence, current_user: local_user)

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    refute Bonfire.Social.FeedLoader.feed_contains?(:my, post, local_user)
  end

  test "does not show in my_feed an incoming Note from a per-user silenced actor that I am following" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    assert {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

    Bonfire.Social.Graph.Follows.follow(local_user, remote_user)

    Bonfire.Boundaries.Blocks.block(remote_user, :silence, current_user: local_user)

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    refute Bonfire.Social.FeedLoader.feed_contains?(:my, post, local_user)
  end

  test "does not show an incoming Note in any feeds when viewed by the user who silenced the actor" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_user} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)

    Bonfire.Boundaries.Blocks.block(user, :silence, current_user: local_user)

    # debug_user_acls(local_user, "local_user")
    # debug_user_acls(local_user, "remote_user")

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    debug_object_acls(post)

    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(:remote, local_user)

    another_local_user = fake_user!()
    # check that we do show it to others
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, another_local_user)
  end

  test "does not show an incoming Note in any feeds when viewed by the user who silenced the actor after the fact" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_user} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)

    {:ok, post} = receive_remote_activity_to([local_user, ActivityPub.Config.public_uri()])

    Bonfire.Boundaries.Blocks.block(user, :silence, current_user: local_user)

    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(:remote, local_user)

    another_local_user = fake_user!()
    # check that we do still show it to others
    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, another_local_user)
  end
end
