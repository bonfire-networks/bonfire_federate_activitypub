defmodule Bonfire.Federate.ActivityPub.ActorIntegrationTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock

  # TODO: move this into fixtures
  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
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
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")
    # IO.inspect(actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    assert actor.data["summary"] == user.profile.summary
    assert actor.data["name"] == user.profile.name
    # IO.inspect(user)
    assert user.profile.icon_id
    assert user.profile.image_id
  end
end
