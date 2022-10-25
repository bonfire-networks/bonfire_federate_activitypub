defmodule Bonfire.Federate.ActivityPub.ActorIntegrationTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock
  import Untangle
  alias Bonfire.Federate.ActivityPub.Utils
  alias Bonfire.Common

  @remote_instance "https://mocked.local"
  @actor_name "karen@mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  @remote_actor_url @remote_instance <> "/@karen"
  @webfinger @remote_instance <>
               "/.well-known/webfinger?resource=acct:" <> @actor_name

  # TODO: move this into fixtures
  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @remote_actor_url} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @webfinger} ->
        json(Simulate.webfingered())

      %{
        method: :get,
        url: "http://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local"
      } ->
        json(Simulate.webfingered())

      other ->
        error(other, "mock not configured")
        nil
    end)

    :ok
  end

  test "fetch user from AP API with AP ID" do
    user = fake_user!()

    # we are trying to check for a cacheing bug, so we do this twice
    build_conn()
    |> get("/pub/actors/#{user.character.username}")
    |> response(200)
    |> Jason.decode!()

    ret =
      build_conn()
      |> get("/pub/actors/#{user.character.username}")
      |> response(200)
      |> Jason.decode!()

    assert ret["preferredUsername"] == user.character.username
    assert ret["name"] =~ user.profile.name
    assert ret["summary"] =~ user.profile.summary
    assert ret["publicKey"]
  end

  test "fetch user from AP API with friendly URL and Accept header" do
    user = fake_user!()

    assert build_conn()
           |> put_req_header("accept", "application/activity+json")
           |> get("/@#{user.character.username}")
           |> redirected_to() =~ "/pub/actors/#{user.character.username}"

    # again with URI encoded to check for a caching bug
    assert build_conn()
           |> put_req_header("accept", "application/activity+json")
           |> get("/%40#{user.character.username}")
           |> redirected_to() =~ "/pub/actors/#{user.character.username}"
  end

  test "serves user in AP API with profile fields" do
    user = fake_user!()

    Bonfire.Me.Settings.put([Bonfire.Me.Users, :undiscoverable], true, current_user: user)

    conn =
      build_conn()
      |> get("/pub/actors/#{user.character.username}")
      |> response(200)
      |> Jason.decode!()

    # |> debug

    assert conn["preferredUsername"] == user.character.username
    assert conn["name"] =~ user.profile.name
    assert conn["summary"] =~ user.profile.summary

    assert conn["icon"]["url"] =~ Common.Utils.avatar_url(user)
    assert conn["image"]["url"] =~ Common.Utils.banner_url(user)

    assert List.first(conn["attachment"])["value"] =~ user.profile.website

    assert conn["publicKey"]

    assert conn["discoverable"] == false
  end

  test "remote actor creation" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    # debug(actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    # |> debug()
    assert Bonfire.Common.Text.text_only(actor.data["summary"]) =~
             Bonfire.Common.Text.text_only(user.profile.summary)

    assert actor.data["name"] =~ user.profile.name
    # debug(user)
    assert user.profile.icon_id
    assert user.profile.image_id
  end

  test "remote actor discoverability flag is preserved" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    assert actor.data["discoverable"] == false

    assert Bonfire.Me.Settings.get([Bonfire.Me.Users, :undiscoverable], false, current_user: user) ==
             true
  end

  test "can follow pointers to remote actors" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    assert {:ok, _} = Common.Pointers.one(user.id)
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

    # assert object1 == object2
    assert object1.id == object2.id
    assert object1.character.id == object2.character.id
    assert object1.profile.id == object2.profile.id
  end

  test "fetches a same actor by AP ID and friendly URL" do
    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@remote_actor)
    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)

    assert object1.id == object2.id
    assert object1.character.id == object2.character.id
    assert object1.profile.id == object2.profile.id
  end

  test "fetches a same actor by webfinger, AP ID and friendly URL" do
    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@actor_name)
    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor)
    {:ok, object3} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)

    assert object1.id == object2.id
    assert object1.character.id == object2.character.id
    assert object1.profile.id == object2.profile.id
    assert object1.id == object3.id
    assert object1.character.id == object3.character.id
    assert object1.profile.id == object3.profile.id
  end

  test "fetches a same actor by AP ID and friendly URL and webfinger" do
    {:ok, object1} = Utils.get_by_url_ap_id_or_username(@remote_actor)
    {:ok, object2} = Utils.get_by_url_ap_id_or_username(@remote_actor_url)
    {:ok, object3} = Utils.get_by_url_ap_id_or_username(@actor_name)

    assert object1.id == object2.id
    assert object1.character.id == object2.character.id
    assert object1.profile.id == object2.profile.id
    assert object1.id == object3.id
    assert object1.character.id == object3.character.id
    assert object1.profile.id == object3.profile.id
  end
end
