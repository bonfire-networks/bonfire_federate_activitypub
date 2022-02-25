defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceMRFInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"
  @local_actor "alice"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  setup do
    orig = Config.get!(:boundaries)

    # local_user = fake_user!(@local_actor)

    Config.put(:boundaries,
      block: [],
      ghost: [],
      silence: []
    )

    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end


  describe "block incoming federation when" do

    test "there's a remote activity with instance-wide silenced host (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide silenced host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      # |> debug
      |> Bonfire.Boundaries.block(:silence, :instance_wide)
      # |> debug

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide silenced wildcard domain" do
      Config.put([:boundaries, :silence], ["*kawen.space"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced host (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      |> Bonfire.Boundaries.block(:silence, :instance_wide)

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced host" do
      Config.put([:boundaries, :silence], ["kawen.space"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced wildcard domain" do
      Config.put([:boundaries, :silence], ["*kawen.space"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced actor (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space/users/karen"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end
  end


  describe "accept incoming federation when" do
    test "there's no silencing (in config)" do
      Config.put([:boundaries, :silence], [])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching remote activity" do
      Config.put([:boundaries, :silence], ["non.matching.remote"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching remote actor" do
      Config.put([:boundaries, :silence], ["non.matching.remote"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor) == {:ok, remote_actor}
    end
  end

  describe "accept when" do

    test "someone from an instance-wide silenced instance attempts to follow" do
      followed = fake_user!()
      {:ok, followed_actor} = ActivityPub.Adapter.get_actor_by_id(followed.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.block(:silence, :instance_wide)

      assert {:ok, follow_activity} = ActivityPub.follow(remote_actor, followed_actor)
      assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)
      assert Bonfire.Social.Follows.following?(remote_user, followed)
    end
  end


  describe "proceed with outgoing federation when" do

    test "there's a local activity with instance-wide silenced host as recipient (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      |> Bonfire.Boundaries.block(:silence, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced wildcard domain as recipient" do
      Config.put([:boundaries, :silence], ["*kawen.space"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space/users/karen"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :silence, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced domain as recipient" do
      Config.put([:boundaries, :silence], ["kawen.space"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end
  end


  describe "do not filter out outgoing recipients when" do

    test "there's a local activity with instance-wide silenced host as recipient (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => [@remote_actor, @public_uri]}
      }
    end

    test "there's a local activity with instance-wide silenced host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      |> Bonfire.Boundaries.block(:silence, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => [@remote_actor, @public_uri]}
      }
    end

    test "there's a local activity with instance-wide silenced wildcard domain as recipient" do
      Config.put([:boundaries, :silence], ["*kawen.space"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => [@remote_actor, @public_uri]},
      }
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in config)" do
      Config.put([:boundaries, :silence], ["kawen.space/users/karen"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => [@remote_actor, @public_uri]}
      }
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :silence, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => [@remote_actor, @public_uri]}
      }
    end

    test "there's a local activity with instance-wide silenced domain as recipient" do
      Config.put([:boundaries, :silence], ["kawen.space"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => [@remote_actor, @public_uri]}
      }
    end
  end

end
