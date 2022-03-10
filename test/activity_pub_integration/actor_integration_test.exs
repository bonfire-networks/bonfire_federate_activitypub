defmodule Bonfire.Federate.ActivityPub.ActorIntegrationTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub.Utils

  @remote_instance "https://kawen.space"
  @actor_name "karen@kawen.space"
  @remote_actor @remote_instance<>"/users/karen"
  @remote_actor_url @remote_instance<>"/@karen"
  @webfinger @remote_instance<>"/.well-known/webfinger?resource=acct:"<>@actor_name

  # TODO: move this into fixtures
  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
      %{method: :get, url: @remote_actor_url} ->
        json(Simulate.actor_json(@remote_actor))
      %{method: :get, url: @webfinger} ->
        json(Simulate.webfingered())
      other ->
        IO.inspect(other, label: "mock not configured")
        nil
    end)

    :ok
  end

  test "fetch users from AP API" do
    user = fake_user!()

    _conn =
      build_conn()
      |> get("/pub/actors/#{user.character.username}")
      |> response(200)
      |> Jason.decode!

    # Fetching twice to check for a caching bug
    conn =
      build_conn()
      |> get("/pub/actors/#{user.character.username}")
      |> response(200)
      |> Jason.decode!

    assert conn["preferredUsername"] == user.character.username
    assert conn["name"] == user.profile.name
    assert conn["summary"] == user.profile.summary
    assert conn["publicKey"]
  end

  test "remote actor creation" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    # debug(actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    assert actor.data["summary"] == user.profile.summary
    assert actor.data["name"] == user.profile.name
    # debug(user)
    assert user.profile.icon_id
    assert user.profile.image_id
  end

  test "can follow pointers to remote actors" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    assert {:ok, _} = Bonfire.Common.Pointers.one(user.id)
  end


  test "fetches an actor by AP ID" do
    {:ok, object} = Utils.get_by_url_ap_id_or_username(@remote_actor)

    assert object
  end

  test "fetches an actor by friendly URL" do
    {:ok, object} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)

    assert object
  end

  test "fetches a same actor by friendly URL and AP ID" do
    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)
    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor)

    assert object1 == object2
  end

  test "fetches a same actor by AP ID and friendly URL" do
    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@remote_actor)
    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)

    assert object2 == object2
  end

  test "fetches a same actor by webfinger, AP ID and friendly URL" do

    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@actor_name)

    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor)
    {:ok, object3} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)

    assert object1 == object2
    assert object2 == object3
  end

  test "fetches a same actor by AP ID and friendly URL and webfinger" do

    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@remote_actor)
    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)

    {:ok, object3} = Utils.get_by_url_ap_id_or_username(@actor_name)

    assert object1 == object2
    assert object2 == object3
  end
end
