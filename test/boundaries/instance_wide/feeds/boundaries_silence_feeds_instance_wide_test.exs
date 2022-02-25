defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceFeedsInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"
  @local_actor "alice"

  setup do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      silence: [],
      ghost: []
    )

    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end


  test "show in feeds a Post for an incoming Note with no silencing" do
    recipient = fake_user!(@local_actor)
    receive_remote_activity_to(recipient)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    #|> debug()
    assert %{edges: [feed_entry]} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

  test "does not show in feeds a Post for an incoming Note frin a silenced instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      |> dump
      ~> Bonfire.Boundaries.block(:silence, :instance_wide)

    recipient = fake_user!(@local_actor)
    receive_remote_activity_to(recipient)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

  test "does not show in feeds a Post for an incoming Note with silenced actor" do
    {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
    Bonfire.Boundaries.block(user, :silence, :instance_wide)

    recipient = fake_user!(@local_actor)
    receive_remote_activity_to([recipient])

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

  @tag :TODO
  test "hides a Post in feeds from a remote instance that was silenced later" do

    recipient = fake_user!(@local_actor)
    receive_remote_activity_to([recipient])

    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      # |> debug
      ~> Bonfire.Boundaries.block(:silence, :instance_wide)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

end
