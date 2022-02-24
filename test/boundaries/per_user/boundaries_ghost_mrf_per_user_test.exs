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
    local_user = fake_user!()
    {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

    %{
      "actor" => local_actor.ap_id,
      "to" => [to]
    }
  end

   defp build_remote_activity_for(to \\ nil) do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

    to = to || (
      local_user = fake_user!()
      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)
      local_actor.ap_id
    )

    context = "blabla"

    to = [
      to,
      "https://www.w3.org/ns/activitystreams#Public"
    ]

    object = %{
      "content" => "content",
      "type" => "Note",
      "to" => to
    }

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to
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

  def prepare_remote_activity_for(recipient) do
    recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)
    params = build_remote_activity_for(recipient_actor.data)
    with {:ok, activity} <- ActivityPub.create(params), do:
      assert {:ok, post} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
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

  describe "block" do

    test "from my feed when there's a remote activity from a per-user blocked instance (in DB/boundaries)" do
      recipient = fake_user!()

      remote_actor_user()
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.block(:ghost, current_user: recipient)

      remote_activity = prepare_remote_activity_for(recipient)

      assert %{edges: []} = Bonfire.Social.FeedActivities.my_feed(recipient)
    end

    test "follow from a per-user blocked instance" do
      followed = fake_user!()
      {:ok, followed_actor} = ActivityPub.Adapter.get_actor_by_id(followed.id)

      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      {:ok, remote_user} = Bonfire.Me.Users.by_username(remote_actor.username)

      remote_user
      |> e(:character, :peered, :peer_id, nil)
      # |> debug
      |> Bonfire.Boundaries.block(:ghost, current_user: followed)

      {:ok, follow_activity} = ActivityPub.follow(remote_actor, followed_actor)

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(follow_activity)
      assert false = Bonfire.Social.Follows.following?(remote_user, followed)
    end

    test "there's a remote actor with per-user blocked host (in DB/boundaries)" do
      Bonfire.Federate.ActivityPub.Actors.get_or_create(@remote_actor)
      |> Bonfire.Boundaries.block(:ghost, :instance_wide)

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

    test "there's a remote actor with per-user blocked actor (in DB/boundaries)" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)

      remote_actor_user()
      |> Bonfire.Boundaries.block(:ghost, current_user: recipient)

      remote_actor = build_remote_actor()

      assert BoundariesMRF.filter(remote_actor) == {:reject, nil}
    end

  end

  describe "filter recipients when" do

    test "there's a local activity with per-user blocked host as recipient (in DB)" do
      Bonfire.Federate.ActivityPub.Actors.get_or_create(@remote_actor)
      |> Bonfire.Boundaries.block(:ghost, :instance_wide)

      local_activity = build_local_activity_for() #|> debug

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => local_activity["actor"], "to" => []}
      }
    end

    test "there's a local activity with per-user blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      local_activity = build_local_activity_for(remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => local_activity["actor"], "to" => []}
      }
    end

    test "there's a remote activity with per-user blocked actor as recipient (in DB)" do
      {:ok, remote_actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
      assert {:ok, user} = Bonfire.Me.Users.by_username(remote_actor.username)
      Bonfire.Boundaries.block(user, :ghost, :instance_wide)

      local_activity = build_local_activity_for(remote_actor)

      assert BoundariesMRF.filter(local_activity) == {:ok,
        %{"actor" => local_activity["actor"], "to" => []}
      }
    end

  end

end
