defmodule Bonfire.Federate.ActivityPub.Boundaries.ActorSilenceMRFPerUserTest do
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


  describe "reject when" do

    test "I try to follow someone on an per-user silenced instance" do
      local_user = fake_user!(@local_actor)

      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

       refute match? {:ok, follow_activity}, ActivityPub.follow(local_actor, remote_actor, nil, true)
      # assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)
      refute Bonfire.Social.Follows.following?(local_user, remote_user)
    end
  end


  describe "accept when" do

    @tag :fixme
    test "someone from an per-user silenced instance attempts to follow" do
      local_user = fake_user!(@local_actor)

      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:silence, current_user: local_user)

      assert {:ok, follow_activity} = ActivityPub.follow(remote_actor, local_actor, nil, false)
      assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)
      assert Bonfire.Social.Follows.requested?(remote_user, local_user)
      # assert Bonfire.Social.Follows.following?(remote_user, local_user)
    end
  end

  describe "proceed with outgoing federation when" do

    test "there's a local activity with per-user silenced actor as recipient" do
      local_user = fake_user!(@local_actor)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :silence, current_user: local_user)

      local_activity = local_activity_json(local_user, [@remote_actor])

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end


  describe "do not filter out outgoing recipients when" do

    test "there's a local activity with per-user silenced actor as recipient" do
      local_user = fake_user!(@local_actor)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :silence, current_user: local_user)

      local_activity = local_activity_json(local_user, [@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: Bonfire.Federate.ActivityPub.Utils.ap_base_url() <>"/actors/"<> @local_actor, to: [@remote_actor, @public_uri]}
      }
    end

  end
end
