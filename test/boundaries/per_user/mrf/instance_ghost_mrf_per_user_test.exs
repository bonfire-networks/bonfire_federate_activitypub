defmodule Bonfire.Federate.ActivityPub.MRFPerUserTest do
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

  describe "do not federate when all recipients are filtered out because" do
    test "there's a local activity with per-user ghosted instance as recipient" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:ghost, current_user: local_user)

      local_activity = local_activity_json(local_user, @remote_actor)

      # assert reject_or_no_recipients? BoundariesMRF.filter(local_activity, true)
      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end
  end

  describe "filter outgoing recipients when" do
    test "there's a local activity with per-user ghosted instance as recipient" do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:ghost, current_user: local_user)

      local_activity =
        local_activity_json(local_user, [@remote_actor, ActivityPub.Config.public_uri()])

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

  describe "accept incoming federation when" do
    test "there's a remote activity with per-user ghosted instance " do
      local_user = fake_user!(@local_actor)

      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      # |> debug
      ~> Bonfire.Boundaries.Blocks.block(:ghost, current_user: local_user)

      # |> debug

      remote_activity = remote_activity_json_to([local_user])

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end
  end
end
