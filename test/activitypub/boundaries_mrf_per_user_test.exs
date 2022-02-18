defmodule Bonfire.Federate.ActivityPub.MRFPerUserTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"

  setup do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      mute: [],
      deafen: []
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
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => ActivityPubWeb.base_url() <> ap_base_path <> "/actors/alice",
      "to" => [to]
    }
  end

   defp build_remote_activity_for(to \\ nil) do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => @remote_actor ,
      "to" => [to || (ActivityPubWeb.base_url() <> ap_base_path <> "/actors/alice")]
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

  def remote_actor_user(actor_uri \\ @remote_actor) do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(actor_uri)
    {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    user
  end


  describe "do not block when" do
    test "there's no matching remote activity" do
      remote_activity = build_activity_from()

      assert BoundariesMRF.filter(remote_activity) == {:ok, remote_activity}
    end

    test "there's no matching a remote actor" do
      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:ok, remote_actor}
    end

    test "there's no matching local activity" do
      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok, local_activity}
    end
  end

  describe "block when" do

    test "there's a remote activity with per-user blocked host (in DB/boundaries)" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)

      remote_actor_user()
      |> e(:character, :peered, :peer_id, nil)
      |> debug
      |> Bonfire.Me.Boundaries.block(recipient)

      remote_activity = build_remote_activity_for(recipient_actor.ap_id)

      assert BoundariesMRF.filter(remote_activity) == {:reject, nil}
    end

    test "there's a remote actor with per-user blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Actors.get_or_create(@remote_actor)
      |> Bonfire.Me.Boundaries.block(:instance)

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with per-user blocked actor (in DB/boundaries)" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)

      remote_actor_user()
      |> Bonfire.Me.Boundaries.block(recipient)

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

  end

  describe "filter recipients when" do

    test "there's a local activity with per-user blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Actors.get_or_create(@remote_actor)
      |> Bonfire.Me.Boundaries.block(:instance)

      local_activity = build_local_activity_for()

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "there's a local activity with per-user blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Me.Boundaries.block(user, :instance)

      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

    test "there's a remote activity with per-user blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Me.Boundaries.block(user, :instance)

      local_activity = build_local_activity_for(@remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => "http://localhost:4000/pub/actors/alice", "to" => []}
      }
    end

  end

end
