defmodule Bonfire.Federate.ActivityPub.GroupModeratorsIncomingTest do
  @moduledoc """
  An `Add` or `Remove` on a moderators collection re-syncs our MIRROR of a group from its origin's list. It is about groups hosted elsewhere: who moderates a group we host is for our own moderators to say, and a remote moderator of ours (promoted by us, after they joined) must not be able to rewrite the list with an activity.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate

  @remote_moderator "https://mocked.local/users/karen"
  @attacker "https://mocked.local/users/attacker"

  setup do
    mock(fn
      %{method: :get, url: @remote_moderator} ->
        json(Bonfire.Federate.ActivityPub.Simulate.actor_json(@remote_moderator))

      %{method: :get, url: @attacker} ->
        # served, so a handler that adopted the activity's list COULD resolve it: unserved, the test would pass for the wrong reason
        json(
          Bonfire.Federate.ActivityPub.Simulate.actor_json(@remote_moderator)
          |> Map.merge(%{
            "id" => @attacker,
            "preferredUsername" => "attacker",
            "inbox" => "#{@attacker}/inbox",
            "outbox" => "#{@attacker}/outbox"
          })
          |> put_in(["publicKey", "id"], "#{@attacker}#main-key")
          |> put_in(["publicKey", "owner"], @attacker)
        )

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    local_moderator = fake_user!()

    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

    # promoted by us once they joined by their own Follow, as the outgoing test does
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_moderator)
    {:ok, remote_person} = Bonfire.Me.Users.by_ap_id(@remote_moderator)

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "type" => "Follow",
               "id" => "#{@remote_moderator}/follows/the-group",
               "actor" => @remote_moderator,
               "object" => group_ap_id
             })

    assert {:ok, _} = Categories.add_moderator(creator, group, id(remote_person))
    assert {:ok, _} = Categories.add_moderator(creator, group, id(local_moderator))

    %{
      creator: creator,
      local_moderator: local_moderator,
      remote_person: remote_person,
      group: group,
      group_ap_id: group_ap_id,
      collection: ActivityPub.Utils.collection_ap_id("moderators", id(group))
    }
  end

  defp moderator_ids(group),
    do: Categories.moderators(group) |> Enum.map(&id/1) |> Enum.sort()

  test "control: the group declares its moderators collection, and the remote moderator is one",
       %{
         group: group,
         group_ap_id: group_ap_id,
         collection: collection,
         creator: creator,
         remote_person: remote_person
       } do
    assert {:ok, %{data: %{"attributedTo" => ^collection}}} =
             ActivityPub.Actor.get_cached(ap_id: group_ap_id),
           "so only the check that it is not a mirror can refuse the Add below"

    assert id(creator) in moderator_ids(group)
    assert id(remote_person) in moderator_ids(group)
  end

  describe "a removal of a post the group itself wrote" do
    # Decided 30 October: a remote moderator of a group we host removing a post the group wrote deletes it, as our own moderators' removal does (`Categories.remove_post_from_group/4`, which has no boost to take away). A stranger's removal of it is refused.
    setup %{group: group, group_ap_id: group_ap_id} do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: group,
          post_attrs: %{post_content: %{html_body: "<p>By the group</p>"}},
          context_id: id(group),
          boundary: "public"
        )

      assert e(Bonfire.Common.Repo.maybe_preload(post, :created), :created, :creator_id, nil) ==
               id(group),
             "control: the group wrote it"

      post = Bonfire.Common.Repo.maybe_preload(post, :peered)

      %{post: post, post_url: Bonfire.Common.URIs.canonical_url(post), group_ap_id: group_ap_id}
    end

    defp removal(actor, post_url, group_ap_id) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Delete",
        "id" => "#{actor}/activities/delete/#{System.unique_integer([:positive])}",
        "actor" => actor,
        "object" => post_url,
        "audience" => group_ap_id,
        "cc" => [group_ap_id],
        "summary" => "off topic"
      }
    end

    defp deliver(activity) do
      ActivityPub.Federator.Transformer.handle_incoming(activity,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: activity["actor"]
      )
    end

    test "a stranger's is refused, and the remote moderator's deletes it", %{
      post: post,
      post_url: post_url,
      group_ap_id: group_ap_id
    } do
      # known to us, or the delivery would die before the part under test
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @attacker)

      deliver(removal(@attacker, post_url, group_ap_id))

      assert {:ok, _} = Bonfire.Common.Needles.get(id(post), skip_boundary_check: true),
             "a stranger removed a post from a group they don't moderate"

      assert {:ok, _} = deliver(removal(@remote_moderator, post_url, group_ap_id))

      assert {:error, _} = Bonfire.Common.Needles.get(id(post), skip_boundary_check: true),
             "the remote moderator's removal of a post the group wrote deletes it"
    end
  end

  test "an Add from its remote moderator, with an inline collection, doesn't rewrite the moderators of a group we host",
       %{group: group, group_ap_id: group_ap_id, collection: collection} do
    before = moderator_ids(group)

    result =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Add",
        "id" => "https://mocked.local/activities/add/#{System.unique_integer([:positive])}",
        "actor" => @remote_moderator,
        "object" => @attacker,
        "target" => %{
          "id" => collection,
          "type" => "OrderedCollection",
          "orderedItems" => [@attacker],
          "totalItems" => 1
        },
        "cc" => [group_ap_id]
      })

    refute match?({:ok, %{pointer: %Bonfire.Classify.Category{}}}, result),
           "a moderator change of a group we host is not handled as a re-sync, got: #{inspect(result)}"

    assert moderator_ids(group) == before,
           "a remote moderator rewrote the moderators of a group we host"
  end
end
