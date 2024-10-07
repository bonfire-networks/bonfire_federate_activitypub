defmodule Bonfire.Federate.ActivityPub.Dance.ModerationDanceTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts

  # TODO
  test "cross-instance flagging", context do
    # context |> info("context")

    local_admin = fake_admin!()
    local_user = context[:local][:user]
    # |> info("local_user")
    local_ap_id =
      Bonfire.Me.Characters.character_url(local_user)
      |> info("local_ap_id")

    remote_ap_id =
      context[:remote][:canonical_url]
      |> info("remote_ap_id")

    # Logger.metadata(action: info("init remote_on_local"))
    # assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    remote_user = context[:remote][:user]

    post1_attrs = %{
      post_content: %{html_body: "#{context[:remote][:username]} try federated flagging"}
    }

    {:ok, post1} =
      Posts.publish(current_user: local_user, post_attrs: post1_attrs, boundary: "public")

    TestInstanceRepo.apply(fn ->
      assert %{edges: feed} = Bonfire.Social.FeedActivities.feed(:my, current_user: remote_user)
      post1remote = List.first(feed).activity.object
      assert post1remote.post_content.html_body =~ "try federated flagging"

      Logger.metadata(action: info("flag it"))

      Bonfire.Social.Flags.flag(remote_user, post1remote)
      |> debug("the flaggg")
    end)

    Logger.metadata(action: info("make sure the incoming flag in queue was processed"))
    Oban.drain_queue(queue: :federator_incoming)

    Logger.metadata(action: info("check flag was federated and is in admin's notifications"))

    assert %{edges: feed} =
             Bonfire.Social.FeedActivities.feed(:notifications, current_user: local_admin)
             |> repo().maybe_preload(activity: [:object])

    %{activity: %{verb_id: verb_id, object: object} = a_remote} = List.first(feed)
    assert verb_id == "71AGSPAM0RVNACCEPTAB1E1TEM"
    assert object.post_content.html_body =~ "try federated flagging"
  end
end
