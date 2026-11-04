if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupNarrowerSyncTest do
    @moduledoc """
    A topic made in a group AFTER another Bonfire mirrored that group shows on the mirror too, in the group. The group tells its followers, with an `Add` of the topic to its `narrower` collection. And the mirror reads that collection (`Categories.maybe_sync_remote_children/1`) when the group's actor is made or updated here, or someone here follows or joins it, at most once an hour per group, fetching the group's actor again first when the one it holds has no `narrower`.

    Each topic here is made as the "New topic" form makes one (`Bonfire.UI.Topics.LiveHandler` and `Bonfire.Classify.LiveHandler.new/3`), not as `fake_category!` makes one.
    """
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    @moduletag :test_instance

    import Bonfire.Federate.ActivityPub.SharedDataDanceCase
    import Bonfire.Classify.Simulate

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias Bonfire.Classify.Categories

    # a public group on the PEER with no topics yet, as `group_or_topic_dance_test.exs` builds one
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

          %{
            creator: creator,
            group: group,
            group_url: Bonfire.Me.Characters.character_url(group)
          }
        end)

      assert {:ok, %Bonfire.Classify.Category{type: :group} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.group_url)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      {:ok, remote: remote, mirror: mirror}
    end

    test "a topic made there after we mirrored the group shows here, in the group", %{
      remote: remote,
      mirror: mirror
    } do
      follow_here!(mirror)
      topic_ap_id = remote_topic_from_form!(remote)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert_mirrored_in(topic_ap_id, mirror)
    end

    # the hour between syncs is let pass by clearing what `maybe_sync_remote_children/1` holds to throttle them
    test "the group's next Update brings a topic made there since", %{
      remote: remote,
      mirror: mirror
    } do
      follow_here!(mirror)
      topic_ap_id = remote_topic_from_form!(remote)
      let_the_sync_interval_pass(mirror)

      rename_there!(remote)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, %{profile: %{name: "Renamed garden"}}} =
               Categories.get(id(mirror), skip_boundary_check: true, preload: :profile),
             "control: the Update arrived"

      assert_mirrored_in(topic_ap_id, mirror)
    end

    # a mirror made before groups declared `narrower` holds an actor without it, as this one does once its stored actor is replaced with one that lacks it
    test "a mirror made before groups listed their topics catches up on the group's next Update",
         %{remote: remote, mirror: mirror} do
      follow_here!(mirror)
      forget_narrower!(mirror)
      topic_ap_id = remote_topic_from_form!(remote)
      let_the_sync_interval_pass(mirror)

      rename_there!(remote)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, %{data: %{"narrower" => narrower}}} =
               ActivityPub.Actor.get_cached(pointer: mirror)

      assert is_binary(narrower), "control: the Update brought the `narrower` URI"

      assert_mirrored_in(topic_ap_id, mirror)
    end

    # nobody here follows the group until then, so nothing the group sends when the topic is made reaches this instance, and only the follow can bring it
    test "a mirror made before groups listed their topics catches up when someone here follows it",
         %{remote: remote, mirror: mirror} do
      forget_narrower!(mirror)
      topic_ap_id = remote_topic_from_form!(remote)
      let_the_sync_interval_pass(mirror)

      assert {:ok, _} = Categories.follow_group(fake_user!(), mirror)

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert_mirrored_in(topic_ap_id, mirror)
    end

    # the "New topic" form's fields, made into params and created as its handlers do, on the peer; returns the topic's AP id
    defp remote_topic_from_form!(remote) do
      TestInstanceRepo.apply(fn ->
        group_id = id(remote.group)

        params =
          %{
            "name" => "Harvest calendar",
            "summary" => "When to pick what",
            "to_boundaries" => "",
            "context_id" => group_id
          }
          |> Map.put("to_boundaries", {:clone, group_id})
          |> Map.drop(["category", "_csrf_token"])
          |> Bonfire.Common.Enums.input_to_atoms()
          |> Map.put(:type, :topic)

        assert {:ok, topic} =
                 Categories.create(remote.creator, %{
                   category: params,
                   parent_category: params[:context_id]
                 })

        assert {:ok, %{ap_id: ap_id}} = ActivityPub.Actor.get_cached(pointer: topic)
        ap_id
      end)
    end

    # someone here follows the mirror, so the group's activities are delivered here
    defp follow_here!(mirror),
      do: assert({:ok, _} = Bonfire.Social.Graph.Follows.follow(fake_user!(), mirror))

    defp rename_there!(remote) do
      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Categories.update(remote.creator, remote.group, %{name: "Renamed garden"})
      end)
    end

    defp let_the_sync_interval_pass(mirror),
      do: Bonfire.Common.Cache.remove("remote_children_sync:#{id(mirror)}")

    # the stored actor replaced, through the AP library's own update, with what an older peer served, ie. without `narrower`
    defp forget_narrower!(mirror) do
      assert {:ok, %{ap_id: ap_id, data: data}} = ActivityPub.Actor.get_cached(pointer: mirror)
      assert is_binary(data["narrower"]), "control: the group declares `narrower`"

      assert {:ok, _} = ActivityPub.Actor.update_actor(ap_id, Map.delete(data, "narrower"), false)

      assert {:ok, %{data: stored}} = ActivityPub.Actor.get_cached(pointer: mirror)
      refute Map.has_key?(stored, "narrower"), "control: the mirror no longer knows of `narrower`"
    end

    defp assert_mirrored_in(topic_ap_id, mirror) do
      assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic_mirror} =
               AdapterUtils.get_character_by_ap_id(topic_ap_id),
             "the topic is mirrored here"

      assert parent_id_of(topic_mirror) == id(mirror), "in its group"
    end

    defp parent_id_of(category) do
      category |> Bonfire.Common.Repo.preload(:tree, force: true) |> e(:tree, :parent_id, nil)
    end
  end
end
