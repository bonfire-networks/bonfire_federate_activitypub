defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceFeedsPerUserTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"
  @local_actor "alice"

  setup do
    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end


  test "shows in feeds an incoming Note with no per-user silencing" do
    local_user = fake_user!(@local_actor)
    receive_remote_activity_to(local_user)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    #|> debug()
    assert %{edges: [feed_entry]} = Bonfire.Social.FeedActivities.feed(feed_id, local_user)
  end

  test "does not show in my_feed an incoming Note from a per-user silenced instance" do
    local_user = fake_user!(@local_actor)
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      # |> debug
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)

    receive_remote_activity_to([local_user, @public_uri])

    assert %{edges: []} = Bonfire.Social.FeedActivities.my_feed(local_user)
  end

  test "does not show in my_feed an incoming Note from a per-user silenced actor that I am not following" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

    Bonfire.Boundaries.block(remote_user, :silence, current_user: local_user)

    receive_remote_activity_to([local_user, @public_uri])

    assert %{edges: []} = Bonfire.Social.FeedActivities.my_feed(local_user)
  end

  test "does not show in my_feed an incoming Note from a per-user silenced actor that I am following" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

    Bonfire.Social.Follows.follow(local_user, remote_user)

    Bonfire.Boundaries.block(remote_user, :silence, current_user: local_user)

    receive_remote_activity_to([local_user, @public_uri])

    assert %{edges: []} = Bonfire.Social.FeedActivities.my_feed(local_user)
  end

  @tag :TODO
  test "does not show in any feeds a Post for an incoming Note from a per-user silenced instance" do
    local_user = fake_user!(@local_actor)
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      # |> debug
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)

    receive_remote_activity_to([local_user, @public_uri])

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, local_user)
  end

  @tag :TODO
  test "does not show in any feeds for an incoming Note from a per-user silenced actor" do
    local_user = fake_user!(@local_actor)
    {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
    Bonfire.Boundaries.block(user, :silence, current_user: local_user)

    receive_remote_activity_to([local_user, @public_uri])

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, local_user)

    another_local_user = fake_user!()
    assert %{edges: [feed_entry]} = Bonfire.Social.FeedActivities.feed(feed_id, another_local_user) # check that we do show it to others
  end

  @tag :TODO
  test "hides a Post in feeds from a remote instance that was per-user silenced later" do

    local_user = fake_user!(@local_actor)
    receive_remote_activity_to([local_user, @public_uri])

    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      # |> debug
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, local_user)
  end

end
