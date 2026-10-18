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

    test "a group there is a group here, and a topic in it a topic, in the group", %{
      remote: remote
    } do
      assert {:ok, %Bonfire.Classify.Category{type: :group} = group_mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic_mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.topic_url)

      assert parent_id_of(topic_mirror) == id(group_mirror), "in its group, as it is there"
      assert parent_id_of(group_mirror) == nil, "control: the group is top-level"
    end

    # the group lists its topics (`narrower`), so mirroring the group alone brings its topics, which nobody here has met yet
    test "mirroring a group brings the topics it lists, underneath it", %{remote: remote} do
      assert {:ok, %Bonfire.Classify.Category{type: :group} = group_mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, topic_ap_id} =
               TestInstanceRepo.apply(fn ->
                 with {:ok, %{ap_id: ap_id}} <- ActivityPub.Actor.get_cached(pointer: remote.topic),
                      do: {:ok, ap_id}
               end)

      assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic_mirror} =
               AdapterUtils.get_character_by_ap_id(topic_ap_id),
             "the topic is mirrored without being fetched itself"

      assert parent_id_of(topic_mirror) == id(group_mirror), "in its group"
    end

    # a topic converted to a group on its own instance keeps its parent there, so it is a subgroup, which names its parent as a topic does but has members of its own
    test "a subgroup there is a group here, in its parent group", %{remote: remote} do
      TestInstanceRepo.apply(fn ->
        assert {:ok, %{type: :group}} =
                 Categories.convert(remote.topic, :group, current_user: remote.creator)
      end)

      assert {:ok, %Bonfire.Classify.Category{type: :group} = subgroup_mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.topic_url)

      assert {:ok, group_mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)
      assert parent_id_of(subgroup_mirror) == id(group_mirror), "in its parent group"
    end

    # archiving a group serves it as a tombstone (Lemmy's community delete), so a peer that doesn't follow it learns of the archive on its next fetch rather than by the `Delete`, and of the restore the same way, finding the group again, still a group.
    # The group-or-topic rule for an archived group is moot now (it is a tombstone); `interop/group_or_topic_test.exs` "a group, when nobody may post but it has members of its own (an archived group)" still covers the rule for other software's actors
    test "an archived group there is a tombstone when fetched here, and a group again once restored",
         %{remote: remote} do
      assert {:ok, %{type: :group} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      # the AP id we hold it under, which any re-fetch uses
      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: mirror)

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Categories.soft_delete(remote.group, remote.creator)
      end)

      assert {:ok, %{"type" => "Tombstone"}} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(group_ap_id,
                 return_tombstones: true
               ),
             "the archived group is still served as itself, so a peer keeps offering a group that accepts nothing"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Categories.unarchive(id(remote.group), remote.creator)
      end)

      assert {:ok, %{data: %{"type" => "Group"}}} =
               ActivityPub.Actor.update_actor(group_ap_id, nil, true),
             "restored at its origin, but still a tombstone to a peer"

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

    defp parent_id_of(category) do
      category |> Bonfire.Common.Repo.preload(:tree, force: true) |> e(:tree, :parent_id, nil)
    end
  end
end
