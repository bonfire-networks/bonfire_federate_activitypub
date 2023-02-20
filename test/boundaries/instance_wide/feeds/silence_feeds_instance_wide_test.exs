defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceFeedsInstanceWideTest do
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

  @tag :fixme
  test "show in feeds an incoming Note with no silencing" do
    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to(recipient)

    assert Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post, recipient)
  end

  test "does not appear in feeds an incoming Note from a silenced instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to(recipient)

    refute Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post, recipient)
  end

  test "does not appear in feeds an incoming Note with silenced actor" do
    {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
    Bonfire.Boundaries.Blocks.block(user, :silence, :instance_wide)

    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([recipient])

    refute Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post, recipient)
  end

  @tag :todo
  test "hides a Post in feeds from a remote instance that was silenced later" do
    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([recipient])

    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

    refute Bonfire.Social.FeedActivities.feed_contains?(:activity_pub, post, recipient)
  end
end
