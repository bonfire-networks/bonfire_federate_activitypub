defmodule Bonfire.Federate.ActivityPub.MRF.ActorBlockInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://mocked.local/users/karen"
  @local_actor "alice"

  setup_all do
    orig = Config.get!(:boundaries)

    # local_user = fake_user!(@local_actor)

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

  describe "block when" do
    test "there's a remote actor with instance-wide blocked actor (in config)" do
      Config.put([:boundaries, :block], ["mocked.local/users/karen"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked actor (in DB/boundaries)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :total, :instance_wide)

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor.data, false))
    end
  end

  describe "block when recipients filtered because" do
    test "there's a local activity with instance-wide blocked actor as recipient (in config)" do
      Config.put([:boundaries, :block], ["mocked.local/users/karen"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "there's a local activity with instance-wide blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :total, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end
  end

  describe "filter recipients when" do
    test "there's a local activity with instance-wide blocked actor as recipient (in config)" do
      Config.put([:boundaries, :block], ["mocked.local/users/karen"])
      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [ActivityPub.Config.public_uri()],
                  data: %{"type" => "Create"}
                }}
    end

    test "there's a local activity with instance-wide blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :total, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [ActivityPub.Config.public_uri()],
                  data: %{"type" => "Create"}
                }}
    end
  end
end
