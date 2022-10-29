defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceMRFInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://mocked.local/users/karen"
  @local_actor "alice"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  setup do
    orig = Config.get!(:boundaries)

    # local_user = fake_user!(@local_actor)

    Config.put(:boundaries,
      block: [],
      ghost_them: [],
      silence_them: []
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
      Config.put([:boundaries, :silence_them], ["mocked.local"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) == {:reject, nil}
    end

    @tag :todo
    test "there's a remote activity with instance-wide silenced host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      # |> debug
      ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

      # |> debug

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide silenced wildcard domain" do
      Config.put([:boundaries, :silence_them], ["*mocked.local"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced host (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:reject, nil}
    end

    @tag :fixme
    test "there's a remote actor with instance-wide silenced host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced host" do
      Config.put([:boundaries, :silence_them], ["mocked.local"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced wildcard domain" do
      Config.put([:boundaries, :silence_them], ["*mocked.local"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide silenced actor (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local/users/karen"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:reject, nil}
    end
  end

  describe "reject when" do
    @tag :fixme
    test "I try to follow someone on an instance-wide silenced instance" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      {:ok, block} =
        remote_user
        |> e(:character, :peered, :peer_id, nil)
        # |> debug
        |> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

      refute match?(
               {:ok, follow_activity},
               ActivityPub.follow(%{actor: local_actor, object: remote_actor, local: true})
             )

      # assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
      refute Bonfire.Social.Follows.following?(local_user, remote_user)
    end
  end

  describe "accept when" do
    @tag :fixme
    test "someone from an instance-wide silenced instance attempts to follow" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

      assert {:ok, follow_activity} =
               ActivityPub.follow(%{actor: remote_actor, object: local_actor, local: false})

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

      assert Bonfire.Social.Follows.requested?(remote_user, local_user)
      # assert Bonfire.Social.Follows.following?(remote_user, local_user)
    end
  end

  describe "accept incoming federation when" do
    test "there's no silencing (in config)" do
      Config.put([:boundaries, :silence_them], [])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end

    test "there's no matching remote activity" do
      Config.put([:boundaries, :silence_them], ["non.matching.remote"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end

    test "there's no matching remote actor" do
      Config.put([:boundaries, :silence_them], ["non.matching.remote"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end
  end

  describe "proceed with outgoing federation when" do
    test "there's a local activity with instance-wide silenced host as recipient (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced wildcard domain as recipient" do
      Config.put([:boundaries, :silence_them], ["*mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local/users/karen"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :silence, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end

    test "there's a local activity with instance-wide silenced domain as recipient" do
      Config.put([:boundaries, :silence_them], ["mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end

  describe "do not filter out outgoing recipients when" do
    test "there's a local activity with instance-wide silenced host as recipient (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [@remote_actor, @public_uri]
                }}
    end

    test "there's a local activity with instance-wide silenced host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:silence, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [@remote_actor, @public_uri]
                }}
    end

    test "there's a local activity with instance-wide silenced wildcard domain as recipient" do
      Config.put([:boundaries, :silence_them], ["*mocked.local"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [@remote_actor, @public_uri]
                }}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in config)" do
      Config.put([:boundaries, :silence_them], ["mocked.local/users/karen"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [@remote_actor, @public_uri]
                }}
    end

    test "there's a local activity with instance-wide silenced actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.Blocks.block(user, :silence, :instance_wide)

      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [@remote_actor, @public_uri]
                }}
    end

    test "there's a local activity with instance-wide silenced domain as recipient" do
      Config.put([:boundaries, :silence_them], ["mocked.local"])
      local_activity = local_activity_json_to([@remote_actor, @public_uri])

      assert BoundariesMRF.filter(local_activity, true) ==
               {:ok,
                %{
                  actor:
                    Bonfire.Federate.ActivityPub.AdapterUtils.ap_base_url() <>
                      "/actors/" <> @local_actor,
                  to: [@remote_actor, @public_uri]
                }}
    end
  end
end
