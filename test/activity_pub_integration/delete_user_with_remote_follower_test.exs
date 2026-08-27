defmodule Bonfire.Federate.ActivityPub.DeleteUserWithRemoteFollowerTest do
  @moduledoc """
  Deleting a user who has a REMOTE follower.

  A plain-test repro attempt for what `dance/delete_user_dance_test.exs:23` hits in CI: the delete
  epic errors with a Postgres `operator does not exist: text | uuid` and rolls the transaction back,
  so the user is never actually deleted (and therefore no `Delete` federates and remote mirrors
  survive). Bare user deletion already works (`bonfire_me` `users_test.exs` "deletion works"), so
  the federated relationships are the suspected ingredient.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Me.Users
  alias Bonfire.Social.Graph.Follows

  @remote_actor "https://mocked.local/users/karen"

  setup do
    test_pid = self()

    mock(fn
      # deliveries have to be mocked now that deleting a user really does federate a `Delete` to its followers: record them so tests can assert on what was sent
      %{method: :post, url: url, body: body} ->
        send(test_pid, {:delivered, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  test "a user with a remote follower can be deleted" do
    local_user = fake_user!()

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    {:ok, remote_user} = Users.by_ap_id(@remote_actor)

    assert {:ok, _follow} = Follows.follow(remote_user, local_user, skip_boundary_check: true)
    assert Follows.following?(remote_user, local_user)

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, _} = Users.enqueue_delete(local_user)
    end)

    assert {:error, :not_found} = Users.by_id(id(local_user)),
           "the user should actually be gone — a rolled back delete transaction leaves them in place"
  end

  test "a user with a remote follower AND a federated post can be deleted" do
    local_user = fake_user!()

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    {:ok, remote_user} = Users.by_ap_id(@remote_actor)

    assert {:ok, _} = Follows.follow(remote_user, local_user, skip_boundary_check: true)

    assert {:ok, _post} =
             Bonfire.Posts.publish(
               current_user: local_user,
               post_attrs: %{post_content: %{html_body: "something to federate"}},
               boundary: "public"
             )

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, _} = Users.enqueue_delete(local_user)
    end)

    assert {:error, :not_found} = Users.by_id(id(local_user)),
           "the user should actually be gone — a rolled back delete transaction leaves them in place"
  end

  # Closest plain-test approximation of the dance: the follow arrives as an actual `Follow` activity and goes through the accept flow, rather than being a row created by calling `Follows.follow/3` directly. Since the query that errors in CI is in `Follows.query_base/2`, what rows the federated path creates may be exactly what differs.
  test "a user with a FEDERATED follower can be deleted" do
    local_user = fake_user!()

    follow = %{
      "type" => "Follow",
      "id" => "#{@remote_actor}/follows/delete-repro",
      "actor" => @remote_actor,
      "object" => Bonfire.Me.Characters.character_url(local_user)
    }

    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(follow)

    {:ok, remote_user} = Users.by_ap_id(@remote_actor)

    assert Follows.following?(remote_user, local_user),
           "the incoming Follow should have been accepted"

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, _} = Users.enqueue_delete(local_user)
    end)

    assert {:error, :not_found} = Users.by_id(id(local_user)),
           "the user should actually be gone — a rolled back delete transaction leaves them in place"
  end

  # The side the dance test's failing assertion is actually about: `remote_on_local` is the MIRROR
  # held by the primary instance, and what fails is that the primary still resolves it after the
  # remote user was deleted at home. That is an INCOMING `Delete` of a remote actor, which needs no
  # dance harness to exercise.
  test "an incoming Delete of a remote actor removes our mirror of them" do
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    {:ok, remote_user} = Users.by_ap_id(@remote_actor)
    assert {:ok, _} = Users.by_id(id(remote_user))

    delete = %{
      "type" => "Delete",
      "id" => "#{@remote_actor}#delete",
      "actor" => @remote_actor,
      "object" => @remote_actor,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    # `check_remote_object_deleted/2` verifies a Delete by re-fetching from the origin, so an actor
    # that is really gone has to stop being served. Without this the guard correctly refuses the
    # Delete, which is also why the dance test fails: the delete ROLLS BACK on the origin instance,
    # so it carries on serving the user and the mirror is kept.
    mock(fn %{method: :get} -> %Tesla.Env{status: 404, body: ""} end)

    Oban.Testing.with_testing_mode(:inline, fn ->
      ActivityPub.Federator.Transformer.handle_incoming(delete)
    end)

    assert {:error, :not_found} = Users.by_id(id(remote_user)),
           "a remote actor deleting themselves at home should remove our mirror of them"
  end

  # The question the dance test actually turns on, asked directly: deleting a user must produce a
  # `Delete` of the actor for their followers, otherwise remote mirrors of them live on forever.
  test "deleting a user federates a Delete of the actor" do
    local_user = fake_user!()

    follow = %{
      "type" => "Follow",
      "id" => "#{@remote_actor}/follows/delete-federation",
      "actor" => @remote_actor,
      "object" => Bonfire.Me.Characters.character_url(local_user)
    }

    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(follow)

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, _} = Users.enqueue_delete(local_user)
    end)

    ap_id = Bonfire.Me.Characters.character_url(local_user)

    all_activities = repo().all(ActivityPub.Object)
    types = all_activities |> Enum.map(&e(&1, :data, "type", nil)) |> Enum.frequencies()

    # Proves the premise before testing the claim: if federation were disabled in this test, NOTHING
    # would be produced and "no Delete" would say nothing about the delete path.
    assert Enum.any?(all_activities, &(e(&1, :data, "type", nil) in ["Accept", "Follow"])),
           "federation appears inactive in this test, so the Delete assertion below would be meaningless — activities present: #{inspect(types)}"

    deletes = all_activities |> Enum.filter(&(e(&1, :data, "type", nil) == "Delete"))

    assert deletes != [],
           "no Delete activity was created at all when deleting a user with a remote follower"

    assert Enum.any?(deletes, fn d ->
             ActivityPub.Object.get_ap_id(e(d, :data, "object", nil)) =~ ap_id
           end),
           "a Delete exists but not for the deleted actor #{ap_id}: #{inspect(Enum.map(deletes, &e(&1, :data, "object", nil)))}"
  end

  test "a user who follows a remote actor can be deleted" do
    local_user = fake_user!()

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    {:ok, remote_user} = Users.by_ap_id(@remote_actor)

    assert {:ok, _follow} = Follows.follow(local_user, remote_user, skip_boundary_check: true)

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, _} = Users.enqueue_delete(local_user)
    end)

    assert {:error, :not_found} = Users.by_id(id(local_user))
  end
end
