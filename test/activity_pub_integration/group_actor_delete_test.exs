defmodule Bonfire.Federate.ActivityPub.GroupActorDeleteTest do
  @moduledoc """
  Deleting a group tells the instances that hold it.

  Groups are ARCHIVED rather than deleted in the product (`Categories.soft_delete/2`, reversible by `unarchive/2`), and archiving stays local on purpose: a federated `Delete` cannot be taken back, so announcing one for a reversible act would strand every remote mirror as a tombstone that `unarchive/2` could never undo. `Categories.hard_delete/2` is the irreversible path, named to pair with `soft_delete/2` so neither can be reached for by accident, and it is the one that federates.

  The machinery is shared with users and already handles non-user actors: `Outgoing.push_delete/4` has a clause for "Topics, Groups, and other non-user actors", and `ActivityPub.delete/3` matches any supported actor type, tombstoning local actors via `Actor.delete/2` so the actor endpoint serves a `Tombstone` afterwards rather than the actor. What is missing is a group deletion that reaches it.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Classify.Simulate
  alias Bonfire.Classify.Categories

  defp federated_group!(creator) do
    Simulate.fake_group!(creator, %{
      membership: "open",
      visibility: "global",
      participation: "anyone",
      default_content_visibility: "public"
    })
  end

  test "deleting a group federates a Delete of its actor" do
    creator = fake_user!()
    group = federated_group!(creator)

    # read the ap_id BEFORE deleting: afterwards the actor is a tombstone and the lookup no longer answers with it
    assert {:ok, %{ap_id: ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

    assert {:ok, _} = Categories.hard_delete(group, current_user: creator)

    assert %{data: %{"type" => "Delete"}} =
             ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
           "a group that disappears without saying so leaves every remote instance holding a community that answers nothing"
  end

  # What a deleted group takes with it, and what it does not. The group's BOOSTS are its own records — the group is the booster, and they are what made its members' posts appear as the group's — so they go. The posts themselves belong to the people who wrote them and survive, which is why "orphaned content" is not a thing here: a post whose group is gone is just a post.
  test "deleting a group deletes its boosts but leaves the posts alone" do
    creator = fake_user!()
    group = federated_group!(creator)
    post = Simulate.fake_post_in_group!(creator, group, "<p>mine, not the group's</p>")

    assert Bonfire.Social.Boosts.boosted?(group, post),
           "control: publishing into a group is what makes the group boost it, so without this the assertion below could pass on a boost that never existed"

    assert {:ok, _} = Categories.hard_delete(group, current_user: creator)

    refute Bonfire.Social.Boosts.boosted?(group, post)

    assert {:ok, _} = Bonfire.Common.Needles.get(id(post), skip_boundary_check: true),
           "the post was written by a person, not by the group, and deleting the group they posted in must not delete what they wrote"
  end

  # The other half of the same act, and the reason archiving must not federate one: this is irreversible for everyone who receives it.
  test "archiving a group federates nothing" do
    creator = fake_user!()
    group = federated_group!(creator)

    assert {:ok, %{ap_id: ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

    assert {:ok, _} = Categories.soft_delete(group, creator)

    refute ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
           "archiving is reversible by `unarchive/2`, and a federated Delete is not, so announcing one would strand every mirror as a tombstone we could never undo"
  end
end
