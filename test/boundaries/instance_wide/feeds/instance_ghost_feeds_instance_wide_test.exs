defmodule Bonfire.Federate.ActivityPub.Boundaries.InstanceGhostFeedsTest do
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

  # test "show in feeds an incoming Note with no ghosting" do
  #   recipient = fake_user!(@local_actor)
  #   {:ok, post} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])

  #   assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post,
  #            current_user: recipient
  #          )
  # end

  test "show in feeds an incoming Note from a ghosted instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
    # |> debug
    ~> Bonfire.Boundaries.Blocks.block(:ghost, :instance_wide)

    recipient = fake_user!(@local_actor)
    {:ok, post} = receive_remote_activity_to([recipient, ActivityPub.Config.public_uri()])

    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post, current_user: recipient)
  end
end
