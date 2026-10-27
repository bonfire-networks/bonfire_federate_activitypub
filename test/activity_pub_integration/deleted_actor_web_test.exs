defmodule Bonfire.Federate.ActivityPub.DeletedActorWebTest do
  @moduledoc """
  A deleted local actor is served as a `Tombstone` at every URL it was known by.

  A peer that re-fetches a deleted actor learns it is gone from the `Tombstone`, so it can drop its copy. An actor has two live URL forms: `/pub/actors/<username>`, and `/pub/group|person|application/<ULID>` for actors created since the instance's ULID cutoff, which is then the actor's AP id. Both have to answer with the tombstone, or a peer holding the id form keeps a copy of an actor that only answers "not found".
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  alias Bonfire.Classify.Simulate
  alias Bonfire.Classify.Categories

  # follows the 301 a live actor's non-canonical URL answers with (`maybe_canonical_redirect/2`), as a peer fetching it would
  defp fetch_actor_json(path) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/activity+json")
      |> get(path)

    case conn.status do
      301 -> conn |> redirected_to(301) |> URI.parse() |> Map.get(:path) |> fetch_actor_json()
      _ -> Jason.decode!(conn.resp_body)
    end
  end

  defp federated_group!(creator) do
    Simulate.fake_group!(creator, %{
      membership: "open",
      visibility: "global",
      participation: "anyone",
      default_content_visibility: "public"
    })
  end

  # archiving is Lemmy's community delete: served as a tombstone until restored, which is also what lets a peer verify the `Delete` it is sent (it goes ahead only once the origin stops serving the group)
  test "an archived group is served as a Tombstone by username and by id, and as the group again once unarchived" do
    creator = fake_user!()
    group = federated_group!(creator)

    assert {:ok, %{username: username}} = ActivityPub.Actor.get_cached(pointer: group)

    assert %{"type" => "Group"} = fetch_actor_json("/pub/actors/#{username}"),
           "control: before archiving the group is served"

    assert {:ok, _} = Categories.soft_delete(group, creator)

    assert %{"type" => "Tombstone"} = fetch_actor_json("/pub/actors/#{username}")

    assert %{"type" => "Tombstone"} = fetch_actor_json("/pub/group/#{id(group)}"),
           "an archived group still served as itself never lets a peer verify the Delete that announces it"

    assert {:ok, _} = Categories.unarchive(id(group), creator)

    assert %{"type" => "Group"} = fetch_actor_json("/pub/actors/#{username}")

    assert %{"type" => "Group"} = fetch_actor_json("/pub/group/#{id(group)}"),
           "the tombstone outlived the archive, so the restored group still reads as gone"
  end

  test "a deleted user is served as a Tombstone by username and by id" do
    user = fake_user!()

    # the actor exists for AP before it is deleted, as it does for any user a peer has fetched
    assert {:ok, %{username: username}} = ActivityPub.Actor.get_cached(pointer: user)

    assert %{"type" => "Person"} = fetch_actor_json("/pub/person/#{id(user)}"),
           "control: before deletion the id URL serves the user"

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, _} = Bonfire.Me.Users.enqueue_delete(user)
    end)

    assert %{"type" => "Tombstone"} = fetch_actor_json("/pub/actors/#{username}"),
           "the username URL, which a peer holding the username form fetches, answered something other than the tombstone"

    # holds only if a deleted user keeps its pointer row, as a deleted group does: today the row is deleted, which sets the tombstone's `pointer_id` to null, so the id URL finds the tombstone by its AP id instead
    # user_id = id(user)
    # assert {:ok, %{data: %{"type" => "Tombstone"}, pointer_id: ^user_id}} =
    #          ActivityPub.Object.get_uncached(ap_id: ap_id),
    #        "the tombstone is not linked to the user's id"

    assert %{"type" => "Tombstone"} = fetch_actor_json("/pub/person/#{id(user)}"),
           "the id URL, which is the actor's AP id for actors created since the ULID cutoff, answered something other than the tombstone, so a peer holding it never learns the user is gone"
  end

  test "a deleted group is served as a Tombstone by username and by id" do
    creator = fake_user!()
    group = federated_group!(creator)

    # the actor exists for AP before it is deleted, as it does for any group a peer has fetched
    assert {:ok, %{username: username}} = ActivityPub.Actor.get_cached(pointer: group)

    assert %{"type" => "Group"} = fetch_actor_json("/pub/group/#{id(group)}"),
           "control: before deletion the id URL serves the group"

    assert {:ok, _} = Categories.hard_delete(group, current_user: creator)

    assert %{"type" => "Tombstone"} = fetch_actor_json("/pub/actors/#{username}"),
           "control: the username URL serves the tombstone"

    assert %{"type" => "Tombstone"} = fetch_actor_json("/pub/group/#{id(group)}"),
           "the id URL, which is the actor's AP id for actors created since the ULID cutoff, answered something other than the tombstone, so a peer holding it never learns the group is gone"
  end
end
