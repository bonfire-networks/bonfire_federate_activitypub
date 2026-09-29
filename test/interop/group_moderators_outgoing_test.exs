defmodule Bonfire.Federate.ActivityPub.GroupModeratorsOutgoingTest do
  @moduledoc """
  Promoting or demoting a moderator of one of our groups tells the group's followers, in the shape Lemmy sends: an `Add` or `Remove` by the moderator who acted, targeting the group's moderators collection, which the group relays as an `Announce`.

  Without it a peer's mirror only learns of the change the next time it refetches the group.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate

  setup do
    mock(fn
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    person = fake_user!()

    %{creator: creator, person: person}
  end

  defp federated_group(creator) do
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    group
  end

  defp ap_id(pointer) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: pointer)
    actor.ap_id
  end

  defp stored(type, actor_ap_id) do
    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(&(&1.local and &1.data["type"] == type and &1.data["actor"] == actor_ap_id))
  end

  test "promoting a moderator sends an Add as the moderator who acted, which the group announces",
       %{creator: creator, person: person} do
    group = federated_group(creator)

    assert {:ok, _} = Categories.add_moderator(creator, group, id(person))

    assert [add] = stored("Add", ap_id(creator))
    assert add.data["object"] == ap_id(person)
    assert add.data["target"] == ActivityPub.Utils.collection_ap_id("moderators", id(group))
    assert add.data["audience"] == ap_id(group)

    assert [announce] = stored("Announce", ap_id(group))
    assert announce.data["object"]["id"] == add.data["id"]
  end

  test "demoting a moderator sends a Remove, which the group announces",
       %{creator: creator, person: person} do
    group = federated_group(creator)
    {:ok, _} = Categories.add_moderator(creator, group, id(person))

    assert {:ok, _} = Categories.remove_moderator(creator, group, id(person))

    assert [remove] = stored("Remove", ap_id(creator))
    assert remove.data["object"] == ap_id(person)
    assert remove.data["target"] == ActivityPub.Utils.collection_ap_id("moderators", id(group))

    assert Enum.any?(
             stored("Announce", ap_id(group)),
             &(&1.data["object"]["id"] == remove.data["id"])
           )
  end

  # paired with the first test, which is what shows a promotion does send when it may
  test "promoting a moderator of a group that does not federate sends nothing",
       %{creator: creator, person: person} do
    group = Simulate.fake_group!(creator)

    assert {:ok, _} = Categories.add_moderator(creator, group, id(person))

    assert [] = stored("Add", ap_id(creator))
  end
end
