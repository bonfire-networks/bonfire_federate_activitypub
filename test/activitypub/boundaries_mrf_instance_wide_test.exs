defmodule Bonfire.Federate.ActivityPub.MRFInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  setup do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      mute: [],
      deafen: []
    )

    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end


  defp build_local_activity_for(to \\ "https://remote.instance/users/bob") do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => ActivityPubWeb.base_url() <> ap_base_path <> "/actors/alice",
      "to" => [to]
    }
  end

  defp build_activity_from(actor \\ "https://remote.instance/users/bob") do
    %{"actor" => actor}
  end

  defp build_remote_actor(actor \\ "https://remote.instance/users/bob") do
    %{
      "id" => actor,
      "type" => "Person"
    }
  end

  describe "do not block when" do
    test "there's no blocks (in config)" do
      Config.put([:boundaries, :block], [])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching remote activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching a remote actor" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:ok, remote_actor}
    end

    test "there's no matching local activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end
  end

  describe "block when" do

    test "there's a remote activity with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["remote.instance"])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://remote.instance")
      # |> debug
      |> Bonfire.Me.Boundaries.block(:instance)
      # |> debug

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["remote.instance"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://remote.instance")
      |> Bonfire.Me.Boundaries.block(:instance)

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide muted host" do
      Config.put([:boundaries, :mute], ["remote.instance"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide blocked actor (in config)" do
      Config.put([:boundaries, :block], ["remote.instance/users/bob"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide blocked actor (in DB/boundaries)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Me.Boundaries.block(user, :instance)

      assert BoundariesMRF.filter(remote_actor.data) == {:reject, nil}
    end

  end

  describe "filter recipients when" do

    test "there's a local activity with instance-wide blocked host as recipient (in config)" do
      Config.put([:boundaries, :block], ["remote.instance"])
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "there's a local activity with instance-wide blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://remote.instance")
      |> Bonfire.Me.Boundaries.block(:instance)

      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "there's a local activity with instance-wide blocked wildcard domain as recipient" do
      Config.put([:boundaries, :block], ["*remote.instance"])
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []},
      }
    end

    test "there's a local activity with instance-wide blocked actor as recipient (in config)" do
      Config.put([:boundaries, :block], ["remote.instance/users/bob"])
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "there's a local activity with instance-wide blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Me.Boundaries.block(user, :instance)

      local_activity = build_local_activity_for("https://kawen.space/users/karen")

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "there's a local activity with instance-wide deafened domain as recipient" do
      Config.put([:boundaries, :deafen], ["remote.instance"])
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end
  end

end
