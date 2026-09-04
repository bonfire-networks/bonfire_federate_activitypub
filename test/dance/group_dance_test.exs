if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupTest do
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    @moduletag :test_instance

    import Untangle
    import Bonfire.Common.Config, only: [repo: 0]
    import Bonfire.Federate.ActivityPub.SharedDataDanceCase
    import Bonfire.Classify.Simulate
    #  import AssertValue

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils

    alias Bonfire.Posts
    alias Bonfire.Social.Graph.Follows

    @tag :test_instance
    test "can lookup group actors from AP API with username, AP ID and with friendly URL",
         context do
      # lookup 3 separate users to be sure
      creator = context[:remote][:user]

      remote = fancy_fake_category_on_test_instance(creator)

      {:ok, %Bonfire.Classify.Category{} = object} =
        AdapterUtils.get_by_url_ap_id_or_username(remote[:username])

      assert object.profile.name == remote[:category].profile.name

      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])
      assert actor.data["type"] == "Group"

      remote = fancy_fake_category_on_test_instance(creator)

      assert {:ok, %Bonfire.Classify.Category{} = object} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      assert object.profile.name == remote[:category].profile.name

      remote = fancy_fake_category_on_test_instance(creator)

      assert {:ok, %Bonfire.Classify.Category{} = object} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:friendly_url])

      assert object.profile.name == remote[:category].profile.name
    end
  end
end
