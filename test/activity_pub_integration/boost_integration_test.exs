defmodule Bonfire.Federate.ActivityPub.BoostIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Social.Boosts

  import Bonfire.Federate.ActivityPub
  import Tesla.Mock

  setup do
    mock(fn
      %{method: :get, url: "https://kawen.space/users/karen"} ->
        json(Simulate.actor_json("https://kawen.space/users/karen"))
    end)

    :ok
  end

  test "boost publishing works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, _ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    {:ok, boost} = Boosts.boost(user, post)

    assert {:ok, _, _} =
             Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{
               args: %{"op" => "create", "context_id" => boost.id}
             })
  end

  test "boost receiving works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")

    {:ok, ap_boost, _} = ActivityPub.announce(actor, ap_activity.object)

    assert {:ok, %Boost{}} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_boost)
  end

  test "unboost receiving works" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Publisher.publish("create", post)

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id("https://kawen.space/users/karen")

    {:ok, ap_boost, _} = ActivityPub.announce(actor, ap_activity.object)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_boost)

    {:ok, ap_unboost, _} = ActivityPub.unannounce(actor, ap_activity.object)

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_unboost)
  end

  # test "boost receiving works, using a raw object" do
  #   ap_boost = %{
  #     data: %{
  #       "object" => %{
  #         "actor" => "https://kawen.space/users/karen",
  #         "cc" => ["https://www.w3.org/ns/activitystreams#Public"],
  #         "context" => nil,
  #         "id" => "https://kawen.space/users/karen/statuses/108585154815961343/activity",
  #         "object" => "https://misskey.bubbletea.dev/notes/9296rwt5fk",
  #         "published" => "2022-07-03T19:52:57.212971Z",
  #         "summary" => nil,
  #         "to" => [
  #           "https://kawen.space/users/karen/followers",
  #           "https://misskey.bubbletea.dev/users/8r0vwokp46"
  #         ],
  #         "type" => "Announce"
  #       }
  #     }
  #   }

  #   assert {:ok, %Boost{}} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(ap_boost) |> repo().maybe_preload(:caretaker, activity: [:subject]) |> debug
  # end
end
