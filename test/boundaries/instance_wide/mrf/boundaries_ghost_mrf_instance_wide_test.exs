defmodule Bonfire.Federate.ActivityPub.MRF.GhostInstanceWideTest do
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
      silence: [],
      ghost: []
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


  describe "reject when" do

    test "someone from an instance-wide ghosted instance attempts to follow" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.block(:ghost, :instance_wide)

      refute match? {:ok, follow_activity}, ActivityPub.follow(remote_actor, local_actor, nil, false)
      # refute match? {:ok, _}, Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)
      refute Bonfire.Social.Follows.following?(remote_user, local_user) #|> dump()
    end

  end

  describe "do not federate when all recipients are filtered out because" do

    test "there's a local activity with instance-wide ghosted host as recipient (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:reject, nil}
    end

    test "there's a local activity with instance-wide ghosted host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      ~> Bonfire.Boundaries.block(:ghost, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:reject, nil}
    end

    test "there's a local activity with instance-wide ghosted wildcard domain as recipient" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:reject, nil}
    end

    test "there's a local activity with instance-wide ghosted actor as recipient (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space/users/karen"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:reject, nil}
    end

    test "there's a local activity with instance-wide ghosted actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:reject, nil}
    end

    test "there's a local activity with instance-wide ghosted domain as recipient" do
      Config.put([:boundaries, :ghost], ["kawen.space"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:reject, nil}
    end
  end

  describe "filter outgoing recipients when" do

    test "there's a local activity with instance-wide ghosted host as recipient (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@public_uri]}
      }
    end

    test "there's a local activity with instance-wide ghosted host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      ~> Bonfire.Boundaries.block(:ghost, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@public_uri]}
      }
    end

    test "there's a local activity with instance-wide ghosted wildcard domain as recipient" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@public_uri]},
      }
    end

    test "there's a local activity with instance-wide ghosted actor as recipient (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space/users/karen"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@public_uri]}
      }
    end

    test "there's a local activity with instance-wide ghosted actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@public_uri]}
      }
    end

    test "there's a local activity with instance-wide ghosted domain as recipient" do
      Config.put([:boundaries, :ghost], ["kawen.space"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) == {:ok,
        %{actor: "http://localhost:4000/pub/actors/" <> @local_actor, to: [@public_uri]}
      }
    end
  end


  describe "proceed with outgoing federation when" do

    test "there's no matching local activity" do
      Config.put([:boundaries, :ghost], ["non.matching.remote"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end

  describe "accept incoming federation when" do

    test "there's a remote activity with instance-wide ghosted host (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) == {:ok, remote_activity}
    end

    test "there's a remote activity with instance-wide ghosted host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      # |> debug
      ~> Bonfire.Boundaries.block(:ghost, :instance_wide)
      # |> debug

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) == {:ok, remote_activity}
    end

    test "there's a remote activity with instance-wide ghosted wildcard domain" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) == {:ok, remote_activity}
    end

    test "there's a remote actor with instance-wide ghosted host (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's a remote actor with instance-wide ghosted host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      ~> Bonfire.Boundaries.block(:ghost, :instance_wide)

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's a remote actor with instance-wide ghosted host" do
      Config.put([:boundaries, :ghost], ["kawen.space"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's a remote actor with instance-wide ghosted wildcard domain" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's a remote actor with instance-wide ghosted actor (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space/users/karen"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's a remote actor with instance-wide ghosted actor (in DB/boundaries)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      assert BoundariesMRF.filter(remote_actor.data, false) == {:ok, remote_actor.data}
    end
  end

end
