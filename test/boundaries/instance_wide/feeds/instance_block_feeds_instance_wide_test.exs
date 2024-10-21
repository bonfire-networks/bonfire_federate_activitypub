defmodule Bonfire.Federate.ActivityPub.Boundaries.InstanceBlockFeedsTest do
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

  test "does not show in feeds a Post for an incoming Note with blocked instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    ~> Bonfire.Boundaries.Blocks.block(:total, :instance_wide)

    recipient = fake_user!(@local_actor)
    assert {:error, _} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])
    # feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    # refute Bonfire.Social.FeedActivities.feed_contains?(feed_id, post, current_user: recipient)
  end

  # duplicate of silencing
  # test "hides a Post in feed from a remote instance that was blocked later" do
  #   recipient = fake_user!(@local_actor)
  #   {:ok, post} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])

  #   Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
  #   # |> debug
  #   ~> Bonfire.Boundaries.Blocks.block(:total, :instance_wide)

  #   feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
  #   refute Bonfire.Social.FeedActivities.feed_contains?(feed_id, post, current_user: recipient)
  # end
end
