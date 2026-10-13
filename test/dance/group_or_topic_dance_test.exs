if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupOrTopicTest do
    @moduledoc """
    Whatever a category is on the instance that hosts it, it is the same on another Bonfire: a group a group, a topic a topic, a subgroup a group, and an archived group still a group. Our actors say which (a group its own `members`; a topic its parent with FEP-9b2b's `broader`, and its parent's `members` or none, and no `openness`), and the peer reads them as it reads any `Group` (`interop/group_or_topic_test.exs` has the same rules against captured actors of other software). Converting one into the other on its own instance converts the peer's mirror too, when the peer hears of it.
    """
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    @moduletag :test_instance

    import Bonfire.Federate.ActivityPub.SharedDataDanceCase
    import Bonfire.Classify.Simulate

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias Bonfire.Classify.Categories

    # a group on the PEER with these dimensions, as `group_dance_test.exs` builds one, and a topic in it
    setup context do
      creator = context[:remote][:user]

      remote =
        TestInstanceRepo.apply(fn ->
          group = fake_group!(creator, %{type: :group})

          :ok =
            Bonfire.Classify.Boundaries.replace(group, creator, %{
              membership: "open",
              visibility: "global",
              participation: "anyone",
              default_content_visibility: "public"
            })

          topic = fake_category!(creator, group, %{type: :topic})

          %{
            creator: creator,
            group: group,
            group_url: Bonfire.Me.Characters.character_url(group),
            topic: topic,
            topic_url: Bonfire.Me.Characters.character_url(topic)
          }
        end)

      {:ok, remote: remote}
    end

    test "a group there is a group here, and a topic in it a topic", %{remote: remote} do
      assert {:ok, %Bonfire.Classify.Category{type: :group}} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      assert {:ok, %Bonfire.Classify.Category{type: :topic}} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.topic_url)
    end

    # a topic converted to a group on its own instance keeps its parent there, so it is a subgroup, which names its parent as a topic does but has members of its own
    test "a subgroup there is a group here", %{remote: remote} do
      TestInstanceRepo.apply(fn ->
        assert {:ok, %{type: :group}} =
                 Categories.convert(remote.topic, :group, current_user: remote.creator)
      end)

      assert {:ok, %Bonfire.Classify.Category{type: :group}} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.topic_url)
    end

    # archiving a group closes it to posting (it declares `postingRestrictedToMods`, as a channel does), but it still has its members, so it stays a group.
    # Seen here on our next fetch of it rather than through its `Update`: archiving doesn't send one (disabled, since delivering it crashed the archive, parked in `group_actor_update_test.exs`).
    # Parked: re-fetching the archived group fails too (`Actor.update_actor/4` → "Cannot update a locally-unknown actor"), so archived groups don't federate at all yet. The rule itself (members of its own keep it a group though nobody may post) is covered by `interop/group_or_topic_test.exs` "a group, when nobody may post but it has members of its own (an archived group)"
    @tag :todo
    @tag skip:
           "archived groups don't federate: no actor Update on archive, and the archived actor can't be re-fetched"
    test "an archived group there is still a group here", %{remote: remote} do
      assert {:ok, %{type: :group} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Categories.soft_delete(remote.group, remote.creator)
      end)

      # our next fetch of it, as any re-fetch would, by the AP id we hold it under
      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: mirror)
      assert {:ok, actor} = ActivityPub.Actor.update_actor(group_ap_id, nil, true)

      assert actor.data["postingRestrictedToMods"] == true,
             "control: the archive reached us, closing it to posting"

      assert {:ok, %{type: :group}} = Categories.get(id(mirror), skip_boundary_check: true)
    end

    # converting on its own instance sends an `Update` of its actor to its followers, which converts the mirror here, both ways
    test "converting there converts it here, both ways", %{remote: remote} do
      assert {:ok, %{type: :topic} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.topic_url)

      follower = fake_user!()
      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(follower, mirror)

      for type <- [:group, :topic] do
        TestInstanceRepo.apply(fn ->
          {:ok, there} = Categories.get(id(remote.topic), skip_boundary_check: true)

          assert {:ok, %{type: ^type}} =
                   Categories.convert(there, type, current_user: remote.creator)
        end)

        assert {:ok, %{type: ^type}} = Categories.get(id(mirror), skip_boundary_check: true),
               "converted to #{type} there"

        assert Bonfire.Social.Graph.Follows.following?(follower, mirror),
               "the follow carries over"
      end
    end
  end
end
