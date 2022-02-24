defmodule Bonfire.Federate.ActivityPub.MRFInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"
  @local_actor "alice"

  setup do
    orig = Config.get!(:boundaries)

    local_user = fake_user!(@local_actor)

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


  defp build_local_activity_for(to \\ @remote_actor) do
    ap_base_path = ActivityPubWeb.base_url() <> System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => ap_base_path <> "/actors/" <> @local_actor,
      "to" => [to]
    }
  end

  defp build_activity_from(actor \\ @remote_actor) do
    %{"actor" => actor}
  end

  defp build_remote_actor(actor \\ @remote_actor) do
    %{
      "id" => actor,
      "type" => "Person"
    }
  end

  describe "do not block when" do
    test "there's no blocks (in config)" do
      Config.put([:boundaries, :ghost], [])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching remote activity" do
      Config.put([:boundaries, :ghost], ["non.matching.remote"])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching a remote actor" do
      Config.put([:boundaries, :ghost], ["non.matching.remote"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:ok, remote_actor}
    end

    test "there's no matching local activity" do
      Config.put([:boundaries, :ghost], ["non.matching.remote"])
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end
  end

  describe "block when" do

    test "there's a remote activity with instance-wide ghosted host (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide ghosted host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      # |> debug
      |> Bonfire.Boundaries.block(:ghost, :instance_wide)
      # |> debug

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote activity with instance-wide ghosted wildcard domain" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])

      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide ghosted host (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide ghosted host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      |> Bonfire.Boundaries.block(:ghost, :instance_wide)

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide ghosted host" do
      Config.put([:boundaries, :ghost], ["kawen.space"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide ghosted wildcard domain" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide ghosted actor (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space/users/karen"])

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with instance-wide ghosted actor (in DB/boundaries)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      assert BoundariesMRF.filter(remote_actor.data) == {:reject, nil}
    end

  end

  describe "filter recipients when" do

    test "there's a local activity with instance-wide ghosted host as recipient (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space"])
      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => []}
      }
    end

    test "there's a local activity with instance-wide ghosted host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://kawen.space")
      |> Bonfire.Boundaries.block(:ghost, :instance_wide)

      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => []}
      }
    end

    test "there's a local activity with instance-wide ghosted wildcard domain as recipient" do
      Config.put([:boundaries, :ghost], ["*kawen.space"])
      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => []},
      }
    end

    test "there's a local activity with instance-wide ghosted actor as recipient (in config)" do
      Config.put([:boundaries, :ghost], ["kawen.space/users/karen"])
      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => []}
      }
    end

    test "there's a local activity with instance-wide ghosted actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => []}
      }
    end

    test "there's a local activity with instance-wide ghosted domain as recipient" do
      Config.put([:boundaries, :ghost], ["kawen.space"])
      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/" <> @local_actor, "to" => []}
      }
    end
  end

end
