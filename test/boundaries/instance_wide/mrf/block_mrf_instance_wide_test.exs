defmodule Bonfire.Federate.ActivityPub.MRF.BlockInstanceWideTest do
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

  describe "do not block when" do
    test "there's no blocks (in config)" do
      Config.put([:boundaries, :block], [])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end

    test "there's no matching remote activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_activity = remote_activity_json()

      assert BoundariesMRF.filter(remote_activity, false) ==
               {:ok, remote_activity}
    end

    test "there's no matching remote actor" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_actor = remote_actor_json()

      assert BoundariesMRF.filter(remote_actor, false) == {:ok, remote_actor}
    end

    test "there's no matching local activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])
      local_activity = local_activity_json_to(@remote_actor)

      assert BoundariesMRF.filter(local_activity, true) == {:ok, local_activity}
    end
  end

  describe "block when" do
    test "attempting to follow from an instance-wide blocked instance" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:total, :instance_wide)

      refute match?(
               {:ok, follow_activity},
               ActivityPub.follow(%{actor: remote_actor, object: local_actor, local: false})
             )

      # refute match? {:ok, _}, Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
      refute Bonfire.Social.Graph.Follows.following?(remote_user, local_user)
    end

    test "attempting to follow someone on an instance-wide blocked instance" do
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Federator.Adapter.get_actor_by_id(local_user.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.Blocks.block(:total, :instance_wide)

      refute match?(
               {:ok, follow_activity},
               ActivityPub.follow(%{actor: local_actor, object: remote_actor, local: true})
             )

      # refute match? {:ok, _}, Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
      refute Bonfire.Social.Graph.Follows.following?(local_user, remote_user)
    end

    test "there's a remote activity with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])

      remote_activity = remote_activity_json()

      {:reject, _} = BoundariesMRF.filter(remote_activity, false)
    end

    test "there's a remote activity with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      # |> debug
      ~> Bonfire.Boundaries.Blocks.block(:block, :instance_wide)

      # |> debug

      remote_activity = remote_activity_json()

      {:reject, _} = BoundariesMRF.filter(remote_activity, false)
    end

    test "there's a remote activity with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*mocked.local"])

      remote_activity = remote_activity_json()

      {:reject, _} = BoundariesMRF.filter(remote_activity, false)
    end

    test "there's a remote actor with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:block, :instance_wide)

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked host" do
      Config.put([:boundaries, :block], ["mocked.local"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

    test "there's a remote actor with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*mocked.local"])

      remote_actor = remote_actor_json()

      assert reject_or_no_recipients?(BoundariesMRF.filter(remote_actor, false))
    end

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
    test "there's a local activity with instance-wide blocked host as recipient (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "there's a local activity with instance-wide blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:block, :instance_wide)

      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

    test "there's a local activity with instance-wide blocked wildcard domain as recipient" do
      Config.put([:boundaries, :block], ["*mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end

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

    test "there's a local activity with instance-wide blocked domain as recipient" do
      Config.put([:boundaries, :block], ["mocked.local"])
      local_activity = local_activity_json_to(@remote_actor)

      assert reject_or_no_recipients?(BoundariesMRF.filter(local_activity, true))
    end
  end

  describe "filter recipients when" do
    test "there's a local activity with instance-wide blocked host as recipient (in config)" do
      Config.put([:boundaries, :block], ["mocked.local"])
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

    test "there's a local activity with instance-wide blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://mocked.local")
      ~> Bonfire.Boundaries.Blocks.block(:block, :instance_wide)

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

    test "there's a local activity with instance-wide blocked wildcard domain as recipient" do
      Config.put([:boundaries, :block], ["*mocked.local"])
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

    test "there's a local activity with instance-wide blocked domain as recipient" do
      Config.put([:boundaries, :block], ["mocked.local"])
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
