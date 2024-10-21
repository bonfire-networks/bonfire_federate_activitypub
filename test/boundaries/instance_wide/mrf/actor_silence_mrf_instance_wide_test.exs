defmodule Bonfire.Federate.ActivityPub.Boundaries.ActorSilenceMRFInstanceWideTest do
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
      ghost_them: [],
      silence_them: []
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

  describe "block incoming federation when" do
    test "there's a remote actor with instance-wide silenced actor (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local/users/karen"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end
  end

  describe "accept incoming federation when" do
    test "there's no silencing (in config)" do
      Config.put([:boundaries, :silence_them], [])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end
  end

  describe "proceed with outgoing federation when" do
    test "there's a local activity with instance-wide silenced actor as recipient (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local/users/karen"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :silence, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end

  describe "do not filter out outgoing recipients when" do
    test "there's a local activity with instance-wide silenced actor as recipient (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local/users/karen"])
      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :silence, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok, local_activity}
    end
  end
end
