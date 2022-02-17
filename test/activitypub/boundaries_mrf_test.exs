defmodule Bonfire.Federate.ActivityPub.MRFTest do
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


  defp build_local_message(to \\ "https://remote.instance/users/bob") do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => ActivityPubWeb.base_url() <> ap_base_path <> "/actors/alice",
      "to" => [to]
    }
  end

  defp build_remote_message(actor \\ "https://remote.instance/users/bob") do
    %{"actor" => actor}
  end

  defp build_remote_user(actor \\ "https://remote.instance/users/bob") do
    %{
      "id" => actor,
      "type" => "Person"
    }
  end

  describe "when :block" do
    test "is empty" do
      Config.put([:boundaries, :block], [])

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:ok, remote_message}
    end

    test "has no matching remote activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:ok, remote_message}
    end

    test "has a remote activity with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["remote.instance"])

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:reject, nil}
    end

    test "has a remote activity with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://remote.instance")
      # |> debug
      |> Bonfire.Me.Boundaries.block(:instance)
      # |> debug

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:reject, nil}
    end

    test "has a remote activity with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:reject, nil}
    end

    test "has no matching a remote actor" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:ok, remote_user}
    end

    test "has a remote actor with instance-wide blocked host (in config)" do
      Config.put([:boundaries, :block], ["remote.instance"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with instance-wide blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://remote.instance")
      |> Bonfire.Me.Boundaries.block(:instance)

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with instance-wide muted host" do
      Config.put([:boundaries, :mute], ["remote.instance"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with instance-wide blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with instance-wide blocked actor (in config)" do
      Config.put([:boundaries, :block], ["remote.instance/users/bob"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with instance-wide blocked actor (in DB/boundaries)" do
      {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
      Bonfire.Me.Boundaries.block(user, :instance)

      assert BoundariesMRF.filter(remote_user.data) == {:reject, nil}
    end

    test "has no matching local activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok, local_message}
    end

    test "has a local activity with instance-wide blocked host as recipient (in config)" do
      Config.put([:boundaries, :block], ["remote.instance"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "has a local activity with instance-wide blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Instances.get_or_create("https://remote.instance")
      |> Bonfire.Me.Boundaries.block(:instance)

      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "has a local activity with instance-wide blocked wildcard domain as recipient" do
      Config.put([:boundaries, :block], ["*remote.instance"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []},
      }
    end

    test "has a local activity with instance-wide blocked actor as recipient (in config)" do
      Config.put([:boundaries, :block], ["remote.instance/users/bob"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "has a local activity with instance-wide blocked actor as recipient (in DB)" do
      {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
      Bonfire.Me.Boundaries.block(user, :instance)

      local_message = build_local_message("https://kawen.space/users/karen")

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "has a local activity with instance-wide deafened domain as recipient" do
      Config.put([:boundaries, :deafen], ["remote.instance"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end
  end

end
