defmodule Bonfire.Federate.ActivityPub.Boundaries.GhostFeedsTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://mocked.local/users/karen"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"
  @local_actor "alice"

  setup do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      silence_them: [],
      ghost_them: []
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

  @tag :fixme
  test "show in feeds an incoming Note with no ghosting" do
    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to(recipient)

    assert Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post,
             current_user: recipient
           )
  end

  test "show in feeds an incoming Note from a ghosted instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    ~> Bonfire.Boundaries.Blocks.block(:ghost, :instance_wide)

    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([recipient, @public_uri])

    assert Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post,
             current_user: recipient
           )
  end

  test "show in feeds an incoming Note with ghosted actor" do
    {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
    Bonfire.Boundaries.Blocks.block(user, :ghost, :instance_wide)

    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([recipient, @public_uri])

    assert Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post,
             current_user: recipient
           )
  end
end
