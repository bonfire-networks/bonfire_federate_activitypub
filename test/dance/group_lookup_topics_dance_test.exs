if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupLookupTopicsTest do
    @moduledoc """
    Someone here finds a group on another Bonfire through search, by its handle or by its URL, and the topics it already had show here, in it.

    The group and its topic are made on the peer as the "New group" and "New topic" forms make them (`Bonfire.Classify.LiveHandler.new/3`, and `Bonfire.UI.Topics.LiveHandler` before it for a topic), and the group is looked up as search looks one up (`Bonfire.Search.LiveHandler`, which calls `AdapterUtils.get_by_url_ap_id_or_username/2` with the person's `user_id`). Jobs run as they run in these tests (inline), so nothing drains a queue by hand.
    """
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    @moduletag :test_instance

    import Bonfire.Federate.ActivityPub.SharedDataDanceCase

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias Bonfire.Classify.Categories

    # the "Open network" preset's dimensions, as the New group form sends them
    @open_network %{
      "membership" => "open",
      "visibility" => "global",
      "participation" => "anyone",
      "default_content_visibility" => "public"
    }

    setup context do
      creator = context[:remote][:user]

      remote =
        TestInstanceRepo.apply(fn ->
          group =
            from_form!(
              creator,
              :group,
              Map.merge(@open_network, %{
                "name" => "Garden #{System.unique_integer([:positive])}",
                "summary" => "Growing things together",
                "context_id" => ""
              })
            )

          topic =
            from_form!(
              creator,
              :topic,
              %{
                "name" => "Harvest calendar",
                "summary" => "When to pick what",
                "to_boundaries" => {:clone, id(group)},
                "context_id" => id(group)
              }
            )

          assert {:ok, %{ap_id: topic_ap_id}} = ActivityPub.Actor.get_cached(pointer: topic)

          %{
            handle: Bonfire.Me.Characters.display_username(group, true),
            url: "#{Bonfire.Common.URIs.base_url()}#{Bonfire.Common.URIs.path(group)}",
            topic_ap_id: topic_ap_id
          }
        end)

      {:ok, remote: remote, searcher: fake_user!()}
    end

    test "a group found by its handle shows the topic it had, in it", %{
      remote: remote,
      searcher: searcher
    } do
      assert {:ok, %Bonfire.Classify.Category{type: :group} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.handle, user_id: id(searcher))

      assert_mirrored_in(remote.topic_ap_id, mirror)
    end

    test "a group found by its URL shows the topic it had, in it", %{
      remote: remote,
      searcher: searcher
    } do
      assert {:ok, %Bonfire.Classify.Category{type: :group} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote.url, user_id: id(searcher))

      assert_mirrored_in(remote.topic_ap_id, mirror)
    end

    # the form's fields made into params and created as `Bonfire.Classify.LiveHandler.new/3` does
    defp from_form!(creator, type, fields) do
      params =
        fields
        |> Map.drop(["category", "_csrf_token"])
        |> Bonfire.Common.Enums.input_to_atoms()
        |> Map.put(:type, type)

      assert [] == Bonfire.Classify.Boundaries.unchosen_dims(params)

      assert {:ok, category} =
               Categories.create(creator, %{
                 category: params,
                 parent_category: params[:context_id]
               })

      category
    end

    defp assert_mirrored_in(topic_ap_id, mirror) do
      assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic_mirror} =
               AdapterUtils.get_character_by_ap_id(topic_ap_id),
             "the topic is mirrored here"

      assert topic_mirror
             |> Bonfire.Common.Repo.preload(:tree, force: true)
             |> e(:tree, :parent_id, nil) == id(mirror),
             "in its group"
    end
  end
end
