defmodule Bonfire.Federate.ActivityPub.MRFTest do
  use Bonfire.Federate.ActivityPub.DataCase
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF

  setup do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      mute: [],
      deafen: []
    )

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end

  defp build_local_message do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => ActivityPubWeb.base_url() <> ap_base_path <> "/actors/alice",
      "to" => ["https://remote.instance/users/bob"]
    }
  end

  defp build_remote_message do
    %{"actor" => "https://remote.instance/users/bob"}
  end

  defp build_remote_user do
    %{
      "id" => "https://remote.instance/users/bob",
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

    test "has a remote activity with a blocked host" do
      Config.put([:boundaries, :block], ["remote.instance"])

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:reject, nil}
    end

    test "has a remote activity with a blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])

      remote_message = build_remote_message()

      assert BoundariesMRF.filter(remote_message) == {:reject, nil}
    end

    test "has no matching a remote actor" do
      Config.put([:boundaries, :block], ["non.matching.remote"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:ok, remote_user}
    end

    test "has a remote actor with a blocked host" do
      Config.put([:boundaries, :block], ["remote.instance"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with a muted host" do
      Config.put([:boundaries, :mute], ["remote.instance"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with a blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has a remote actor with a blocked actor" do
      Config.put([:boundaries, :block], ["remote.instance/users/bob"])

      remote_user = build_remote_user()

      assert BoundariesMRF.filter(remote_user) == {:reject, nil}
    end

    test "has no matching local activity" do
      Config.put([:boundaries, :block], ["non.matching.remote"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok, local_message}
    end

    test "has a local activity for a blocked host" do
      Config.put([:boundaries, :block], ["remote.instance"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "has a local activity for a blocked wildcard domain" do
      Config.put([:boundaries, :block], ["*remote.instance"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []},
      }
    end

    test "has a local activity for a blocked actor" do
      Config.put([:boundaries, :block], ["remote.instance/users/bob"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "has a local activity for a deafened domain" do
      Config.put([:boundaries, :deafen], ["remote.instance"])
      local_message = build_local_message()

      assert BoundariesMRF.filter(local_message) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end
  end

end
