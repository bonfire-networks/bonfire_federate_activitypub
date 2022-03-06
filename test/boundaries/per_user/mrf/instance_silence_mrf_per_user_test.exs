defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceMRFPerUserTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"
  @local_actor "alice"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  setup do

    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

  end


  describe "block incoming federation when" do

    test "there's a remote activity from a per-user silenced instance" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      # |> debug
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)
      # |> debug

      remote_activity = remote_activity_json_to(local_user)

      assert BoundariesMRF.filter(remote_activity, false) == {:reject, nil}
    end

  end

  describe "filter incoming recipients when" do

    test "there's a remote activity from a per-user silenced instance" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      # |> debug
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)
      # |> debug

      remote_activity = remote_activity_json_to([local_user, @public_uri])

      assert {:ok, %{to: [@public_uri]}} = BoundariesMRF.filter(remote_activity, false)
    end

  end


  describe "proceed with outgoing federation when" do

    test "there's a local activity with per-user silenced host as recipient" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)

      local_activity = local_activity_json(local_user, [@remote_actor])

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

  end


  describe "do not filter out outgoing recipients when" do

    test "there's a local activity with per-user silenced host as recipient" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      ~> Bonfire.Boundaries.block(:silence, current_user: local_user)

      local_activity = local_activity_json(local_user, [@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@remote_actor, @public_uri]}
      }
    end

  end
end
