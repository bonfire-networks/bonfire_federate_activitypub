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

  describe "accept when" do
    test "someone from an per-user silenced instance attempts to follow" do
      local_user = fake_user!(@local_actor)

      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

      assert {:ok, follow_activity} =
               ActivityPub.follow(%{actor: remote_actor, object: local_actor, local: false})

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

      # assert Bonfire.Social.Graph.Follows.requested?(remote_user, local_user)
      assert Bonfire.Social.Graph.Follows.following?(remote_user, local_user)
    end
  end

  describe "reject when" do
    test "I try to follow someone on an per-user silenced instance" do
      local_user = fake_user!(@local_actor)

      # {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      # {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      # {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)
      assert {:ok, remote_user} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
                 @remote_actor
               )

      assert {:ok, instance} =
               Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
               |> debug("iiiii")

      peer =
        e(remote_user, :character, :peered, :peer, nil) || e(remote_user, :peered, :peer, nil) ||
          e(remote_user, :character, :peered, :peer_id, nil) ||
          e(remote_user, :peered, :peer_id, nil)

      assert uid(peer) == uid(instance)

      {:ok, block} =
        instance
        |> debug("peeeeer")
        |> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

      assert Bonfire.Federate.ActivityPub.Instances.instance_blocked?(instance, :silence,
               current_user: local_user
             )

      refute match?(
               {:ok, follow_activity},
               Bonfire.Social.Graph.Follows.follow(local_user, remote_user)
               #  ActivityPub.follow(%{actor: local_actor, object: remote_actor, local: true})
             )

      # assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
      refute Bonfire.Social.Graph.Follows.following?(local_user, remote_user)
    end
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

      assert Bonfire.Federate.ActivityPub.Instances.instance_blocked?(instance, :silence,
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
