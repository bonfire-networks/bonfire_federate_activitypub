defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceMRFPerUserTest do
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

  describe "block incoming federation when" do
    test "there's a remote activity from a per-user silenced instance" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      # |> debug
      ~> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

      # |> debug

      remote_activity = remote_activity_json_to(local_user)

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_activity, false))
    end
  end

  describe "filter incoming recipients when" do
    test "there's a remote activity from a per-user silenced instance" do
      local_user = fake_user!(@local_actor)

      assert {:ok, instance} =
               Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")

      # |> debug

      assert Bonfire.Boundaries.Blocks.block(instance, :silence, current_user: local_user)

      assert Bonfire.Federate.ActivityPub.Instances.is_blocked?(instance, :silence,
               current_user: local_user
             )

      public_uri = ActivityPub.Config.public_uri()

      remote_activity = remote_activity_json_to([local_user, public_uri])
      # local_user should have been stripped
      assert {:ok, %{to: [public_uri]}} = BoundariesMRF.filter(remote_activity, false)
    end
  end

  describe "proceed with outgoing federation when" do
    test "there's a local activity with per-user silenced host as recipient" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

      local_activity = local_activity_json(local_user, [@remote_actor])

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end

  describe "do not filter out outgoing recipients when" do
    test "there's a local activity with per-user silenced host as recipient" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

      local_activity =
        local_activity_json(local_user, [@remote_actor, ActivityPub.Config.public_uri()])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok, local_activity}
    end
  end
end
