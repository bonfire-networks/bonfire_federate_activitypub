defmodule Bonfire.Federate.ActivityPub.PostDataIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias Bonfire.Social.Posts
  alias Bonfire.Common.Text

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    :ok
  end

  test "posts get queued to federate" do
    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    user = fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(post)
    assert %{__struct__: ActivityPub.Object} = ap_activity

    Oban.Testing.assert_enqueued(repo(),
      worker: ActivityPub.Workers.PublisherWorker,
      args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
    )
  end

  test "Post publishing works" do
    user = fake_user!()
    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    # debug(ap_activity)
    assert ap_activity.object.data["content"] =~ post.post_content.html_body
  end

  test "does not publish private Posts with no recipients" do
    user = fake_user!()

    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "mentions")

    assert_raise(FunctionClauseError, fn ->
      Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
    end)
  end

  test "does not publish private Posts publicly" do
    user = fake_user!()
    to = fake_user!()

    attrs = %{post_content: %{html_body: "note to @#{to.character.username} "}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "mentions")

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    # debug(ap_activity)
    assert Text.maybe_markdown_to_html(post.post_content.html_body) =~
             ap_activity.object.data["content"]

    assert @public_uri not in ap_activity.data["to"]
  end

  test "Reply publishing works (if also @ mentioning the OP)" do
    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    user = fake_user!()
    ap_user = ActivityPub.Actor.get_cached!(pointer: user.id)
    replier = fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, original_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "@#{user.character.username} epic response"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: replier,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post_reply)

    assert ap_activity.object.data["inReplyTo"] ==
             original_activity.object.data["id"]

    assert ap_user.ap_id in ap_activity.data["to"]
  end

  test "mention publishing works" do
    me = fake_user!()
    mentioned = fake_user!()
    ap_user = ActivityPub.Actor.get_cached!(pointer: mentioned.id)
    msg = "hey @#{mentioned.character.username} you have an epic text message"
    attrs = %{post_content: %{html_body: msg}}

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    assert ap_user.ap_id in ap_activity.data["to"]
  end

  test "creates a Post for an incoming Note" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

    to = [
      recipient_actor.ap_id,
      @public_uri
    ]

    params = remote_activity_json(actor, to)

    {:ok, activity} = ActivityPub.create(params)

    assert actor.data["id"] == activity.data["actor"]
    assert params.object["content"] == activity.object.data["content"]

    assert {:ok, post} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
             |> repo().maybe_preload(:post_content)

    assert post.post_content.html_body =~ params.object["content"]

    feed_id =
      Bonfire.Social.Feeds.named_feed_id(:activity_pub)
      |> info("feeeed")

    assert Bonfire.Social.FeedActivities.feed_contains?(feed_id, post, current_user: recipient)
           |> info()

    # debug(feed_entry)
  end

  test "creates a Post for an incoming Note with the Note's published date" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

    to = [
      recipient_actor.ap_id,
      @public_uri
    ]

    params = remote_activity_json(actor, to)

    {:ok, activity} = ActivityPub.create(params)

    assert actor.data["id"] == activity.data["actor"]
    assert params.object["content"] == activity.object.data["content"]

    assert {:ok, post} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
             |> repo().maybe_preload(:post_content)

    assert post.post_content.html_body =~ params.object["content"]

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)

    assert %{edges: [feed_entry]} =
             Bonfire.Social.FeedActivities.feed_with_object(feed_id, post, current_user: recipient)

    date =
      feed_entry.activity.object_id
      |> DatesTimes.date_from_pointer()
      |> DateTime.to_iso8601()
      # it has sprouted a milliseconds field and won't print identically
      |> String.replace(".000", "")

    assert date == params.object["published"]
  end

  test "creates a reply for an incoming note with a reply" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

    to = [
      recipient_actor.ap_id,
      @public_uri
    ]

    params = remote_activity_json(actor, to)

    {:ok, activity} = ActivityPub.create(params)

    assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

    reply_object = %{
      "id" => @remote_instance <> "/pub/" <> Pointers.ULID.autogenerate(),
      "content" => "content",
      "type" => "Note",
      "inReplyTo" => activity.object.data["id"]
    }

    reply_params = %{
      actor: actor,
      object: reply_object,
      to: to,
      context: nil
    }

    {:ok, reply_activity} = ActivityPub.create(reply_params)

    assert {:ok, reply} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(reply_activity)

    assert reply.replied.reply_to_id == post.id
  end

  test "does not set public circle for remote objects not addressed to AP public URI" do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient = fake_user!()
    recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

    to = [
      recipient_actor.ap_id
    ]

    params = remote_activity_json(actor, to)

    {:ok, activity} = ActivityPub.create(params)

    assert actor.data["id"] == activity.data["actor"]
    assert params.object["content"] == activity.object.data["content"]

    assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

    assert Bonfire.Boundaries.Circles.circles()[:guest] not in Bonfire.Social.FeedActivities.feeds_for_activity(
             post.activity
           )
  end
end
