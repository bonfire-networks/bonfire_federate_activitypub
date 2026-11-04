defmodule Bonfire.Federate.ActivityPub.GroupNarrowerFederationTest do
  @moduledoc """
  A topic made in one of our groups tells the group's followers, so a peer's mirror of the group shows it without waiting for its next sync: an `Add` of the topic to the group's `narrower` collection by whoever made it, which the group relays as an `Announce`, as a change to its moderators is sent.

  And a mirror here, of a group hosted elsewhere, receiving that `Add` mirrors the topic and files it in the group, when the topic names that group as its `broader`.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @public_dims %{
    membership: "open",
    visibility: "global",
    participation: "anyone",
    default_content_visibility: "public"
  }

  defp ap_id(pointer) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: pointer)
    actor.ap_id
  end

  defp stored(type, actor_ap_id) do
    ActivityPub.Object
    |> repo().all()
    |> Enum.filter(&(&1.local and &1.data["type"] == type and &1.data["actor"] == actor_ap_id))
  end

  # the "New topic" form's fields, made into params and created as `Bonfire.UI.Topics.LiveHandler` and `Bonfire.Classify.LiveHandler.new/3` do
  defp topic_from_form!(creator, group) do
    params =
      %{
        "name" => "Harvest calendar",
        "summary" => "When to pick what",
        "to_boundaries" => {:clone, id(group)},
        "context_id" => id(group)
      }
      |> Bonfire.Common.Enums.input_to_atoms()
      |> Map.put(:type, :topic)

    assert {:ok, topic} =
             Categories.create(creator, %{category: params, parent_category: params[:context_id]})

    topic
  end

  describe "a topic made in one of our groups" do
    setup do
      mock(fn
        %{method: :post} -> %Tesla.Env{status: 202, body: ""}
        %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      end)

      creator = fake_user!()
      group = Simulate.fake_group!(creator)
      :ok = Bonfire.Classify.Boundaries.replace(group, creator, @public_dims)

      %{creator: creator, group: group}
    end

    test "sends an Add of it to the group's narrower collection, which the group announces", %{
      creator: creator,
      group: group
    } do
      topic = topic_from_form!(creator, group)

      assert [add] = stored("Add", ap_id(creator))
      assert add.data["object"] == ap_id(topic)
      assert add.data["target"] == ActivityPub.Utils.collection_ap_id("narrower", id(group))
      assert add.data["audience"] == ap_id(group)

      assert [announce] = stored("Announce", ap_id(group))
      assert announce.data["object"]["id"] == add.data["id"]
    end

    # paired with the test above, which shows a topic does send when it may
    test "in a group that does not federate sends nothing", %{creator: creator} do
      group =
        Simulate.fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors",
          default_content_visibility: "local"
        })

      topic_from_form!(creator, group)

      assert stored("Add", ap_id(creator)) == []
    end
  end

  describe "a mirror receiving an Add to its group's narrower collection" do
    @group "https://bonfire.local/pub/actors/garden"
    @narrower "https://bonfire.local/pub/collections/narrower/garden"
    @topic "https://bonfire.local/pub/actors/harvest"
    @member "https://bonfire.local/pub/actors/karen"
    @stranger "https://elsewhere.local/users/stranger"

    defp person(id) do
      Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
      |> Map.merge(%{
        "id" => id,
        "preferredUsername" => "p#{System.unique_integer([:positive])}",
        "inbox" => "#{id}/inbox",
        "outbox" => "#{id}/outbox"
      })
      |> put_in(["publicKey", "id"], "#{id}#main-key")
      |> put_in(["publicKey", "owner"], id)
    end

    defp category_actor(id, extra) do
      person(id)
      |> Map.merge(%{
        "type" => "Group",
        "followers" => "#{id}/followers",
        "attributedTo" => "#{id}/moderators"
      })
      |> Map.merge(extra)
    end

    defp serve(served) do
      mock(fn
        %{method: :get, url: url} ->
          case served[url] do
            nil -> %Tesla.Env{status: 404, body: ""}
            body -> json(body)
          end

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}
      end)
    end

    setup do
      served = %{
        @group =>
          category_actor(@group, %{
            "narrower" => @narrower,
            "members" => "https://bonfire.local/pub/collections/members/garden",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        # listed nowhere yet when the group is mirrored, as a topic made after that
        @narrower => %{
          "id" => @narrower,
          "type" => "OrderedCollection",
          "totalItems" => 0,
          "orderedItems" => []
        },
        @topic => category_actor(@topic, %{"broader" => @group}),
        @member => person(@member),
        @stranger => person(@stranger)
      }

      serve(served)

      assert {:ok, %Bonfire.Classify.Category{type: :group} = mirror} =
               Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @group})

      assert {:error, :not_found} = AdapterUtils.get_character_by_ap_id(@topic),
             "control: the topic isn't mirrored yet"

      %{mirror: mirror, served: served}
    end

    # the topic mirrored while its actor named no group, as one mirrored before it was in this group, and then served naming it
    defp mirrored_unfiled!(served) do
      serve(Map.put(served, @topic, category_actor(@topic, %{})))

      assert {:ok, %Bonfire.Classify.Category{} = topic} =
               Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @topic})

      assert parent_id_of(topic) == nil, "control: in no group yet"

      serve(served)
      topic
    end

    defp parent_id_of(category),
      do: category |> repo().preload(:tree, force: true) |> e(:tree, :parent_id, nil)

    defp add_from(actor) do
      {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: actor)

      ActivityPub.Federator.Transformer.handle_incoming(
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "type" => "Add",
          "id" => "#{actor}/activities/add/#{System.unique_integer([:positive])}",
          "actor" => actor,
          "object" => @topic,
          "target" => @narrower,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [@group, @topic],
          "audience" => @group
        },
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: actor
      )
    end

    test "mirrors the topic, in the group", %{mirror: mirror} do
      add_from(@member)

      assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic} =
               AdapterUtils.get_character_by_ap_id(@topic)

      assert parent_id_of(topic) == id(mirror)
    end

    test "from someone on the group's host files a topic we held already in the group", %{
      mirror: mirror,
      served: served
    } do
      topic = mirrored_unfiled!(served)

      add_from(@member)

      assert parent_id_of(topic) == id(mirror)
    end

    # paired with the test above: an `Add` makes us fetch the topic again, which only someone with standing in the group may
    test "from someone on another host leaves a topic we held already where it was", %{
      served: served
    } do
      topic = mirrored_unfiled!(served)

      add_from(@stranger)

      assert parent_id_of(topic) == nil
    end
  end
end
