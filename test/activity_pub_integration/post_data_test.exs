defmodule Bonfire.Federate.ActivityPub.PostDataTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias Bonfire.Posts
  alias Bonfire.Common.Text
  use Mneme
  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: "https://developer.mozilla.org/en-US/docs/Web/API/"} ->
        %Tesla.Env{status: 200, body: "<title>Web API</title>"}
    end)

    :ok
  end

  describe "" do
    test "local posts get queued to federate" do
      attrs = %{
        post_content: %{
          summary: "summary",
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
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
      )
    end

    test "creates a Note for short posts" do
      user = fake_user!()
      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      # debug(ap_activity)
      assert ap_activity.object.data["content"] =~ post.post_content.html_body
      assert ap_activity.object.data["type"] == "Note"
    end

    test "creates a Note for short posts with an external link" do
      user = fake_user!()
      content = "content"
      link = "https://developer.mozilla.org/en-US/docs/Web/API/"
      attrs = %{post_content: %{html_body: "#{content} #{link}"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      # debug(ap_activity)
      assert ap_activity.object.data["content"] =~ content
      assert ap_activity.object.data["content"] =~ link
      assert ap_activity.object.data["type"] == "Note"
      # TODO: when we attach link metadata
      # assert is_list(ap_activity.object.data["tag"]) and ap_activity.object.data["tag"] != []
    end

    test "creates a Note for short posts with an internal link" do
      user = fake_user!()
      content = "content"
      link = "https://developer.mozilla.org/en-US/docs/Web/API/"
      attrs = %{post_content: %{html_body: "#{content} [a link](#{link})"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      # debug(ap_activity)
      assert ap_activity.object.data["content"] =~ content
      assert ap_activity.object.data["content"] =~ link
      assert ap_activity.object.data["type"] == "Note"
      # TODO: when we attach link metadata
      # assert is_list(ap_activity.object.data["tag"]) and ap_activity.object.data["tag"] != []
    end

    test "creates an Article for long posts with a title" do
      user = fake_user!()

      attrs = %{
        post_content: %{name: "title", html_body: String.duplicate("very long content ", 100)}
      }

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      # debug(ap_activity)
      assert (ap_activity.object.data["content"] || ap_activity.object.data["summary"]) =~
               post.post_content.html_body

      assert ap_activity.object.data["type"] == "Article"
      assert ap_activity.object.data["preview"]["type"] == "Note"
    end

    test "Outgoing federated can be disabled by each user" do
      user = fake_user!()

      user =
        Bonfire.Federate.ActivityPub.disable(user)
        ~> current_user()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert_raise(RuntimeError, fn ->
        Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
        |> debug
      end)
    end

    test "does not publish private Posts with no recipients" do
      user = fake_user!()

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "mentions")

      assert_raise(RuntimeError, fn ->
        Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
        |> debug
      end)
    end

    test "does not publish private Posts publicly" do
      user = fake_user!()
      to = fake_user!()

      content = "a note to"
      mention = to.character.username
      attrs = %{post_content: %{html_body: "#{content} @#{mention}"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "mentions")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      # debug(ap_activity)
      assert ap_activity.object.data["content"] =~ content
      assert ap_activity.object.data["content"] =~ mention

      assert ActivityPub.Config.public_uri() not in ap_activity.data["to"]
    end

    test "Reply publishing works (if also @ mentioning the OP)" do
      attrs = %{
        post_content: %{
          summary: "summary",
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

      assert ap_user.ap_id in ap_activity.data["to"] or ap_user.ap_id in ap_activity.data["cc"]
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

      assert ap_user.ap_id in ap_activity.data["to"] or ap_user.ap_id in ap_activity.data["cc"]
    end

    test "creates a Post for an incoming public Note" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      to = [
        ActivityPub.Config.public_uri()
      ]

      params = remote_activity_json(actor, to)

      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert params.object["content"] == activity.object.data["content"]

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(:post_content)

      assert post.post_content.html_body =~ params.object["content"]

      assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post)

      # debug(feed_entry)
    end

    test "creates a Post for an incoming public Note with link and fetches link metadata" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      to = [
        ActivityPub.Config.public_uri()
      ]

      # Create a Note with a link but no attachment/preview
      content = "Check out this great link: "
      link_url = "https://developer.mozilla.org/en-US/docs/Web/API/"
      content_with_link = "#{content} <a href=\"#{link_url}\">a link</a>"

      object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "content" => content_with_link,
        "type" => "Note",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "attributedTo" => actor.ap_id,
        "to" => to
      }

      params = %{
        actor: actor,
        object: object,
        to: to,
        context: nil
      }

      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert activity.object.data["content"] =~ link_url

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload([:post_content, :media])

      assert post.post_content.html_body =~ content
      assert post.post_content.html_body =~ link_url

      # Verify that link preview metadata was fetched locally
      assert length(post.media || []) > 0

      link_preview =
        List.first(post.media)
        |> debug("link_preview")

      assert String.trim_trailing(link_preview.path, "/") == String.trim_trailing(link_url, "/")
      assert e(link_preview.metadata, "other", "title", nil) =~ "Web API"

      assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post)
    end

    test "creates a Post and notifies mentioned users for an incoming public Note" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      to = [
        recipient_actor,
        ActivityPub.Config.public_uri()
      ]

      params = remote_activity_json_with_mentions(actor, to)
      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert params.object["content"] == activity.object.data["content"]

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(:post_content)

      assert post.post_content.html_body =~ params.object["content"]

      assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post)

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
               current_user: recipient
             )
    end

    test "creates a Post but does not notify mentioned user who has federation disabled" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      recipient = fake_user!()

      recipient =
        Bonfire.Federate.ActivityPub.disable(recipient)
        ~> current_user()

      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      to = [
        recipient_actor,
        ActivityPub.Config.public_uri()
      ]

      params = remote_activity_json_with_mentions(actor, to)

      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert params.object["content"] == activity.object.data["content"]

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(:post_content)

      assert post.post_content.html_body =~ params.object["content"]

      assert Bonfire.Social.FeedLoader.feed_contains?(:remote, post)

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
               current_user: recipient
             )

      # debug(feed_entry)
    end

    test "creates a Post for an incoming Note with the Note's published date" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      to = [
        recipient_actor,
        ActivityPub.Config.public_uri()
      ]

      params = remote_activity_json(actor, to)

      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert params.object["content"] == activity.object.data["content"]

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
               |> repo().maybe_preload(:post_content)

      assert post.post_content.html_body =~ params.object["content"]

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(:remote, post, current_user: recipient)

      date =
        activity.object_id
        |> DatesTimes.date_from_pointer()
        |> DateTime.to_iso8601()
        # it has sprouted a milliseconds field and won't print identically
        |> String.replace(".000", "")

      assert date == params.object["published"]
    end

    test "creates a reply for an incoming note" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      to = [
        recipient_actor.ap_id,
        ActivityPub.Config.public_uri()
      ]

      params = remote_activity_json(actor, to)

      {:ok, activity} = ActivityPub.create(params)

      assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

      reply_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
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

    test "creates a private reply for an incoming public note" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      to = [
        recipient_actor.ap_id,
        ActivityPub.Config.public_uri()
      ]

      params = remote_activity_json(actor, to)

      {:ok, activity} = ActivityPub.create(params)

      assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

      to = [
        recipient_actor.ap_id
      ]

      reply_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
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

      assert {:ok, %Bonfire.Data.Social.Post{} = reply} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(reply_activity)

      assert reply.replied.reply_to_id == post.id
    end

    test "does not set public circle for remote objects not addressed to AP public URI" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
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

    test "object is cached after post creation" do
      user = fake_user!()
      attrs = %{post_content: %{html_body: "cache test"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")
      {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
      pointer_id = post.id

      assert ap_activity.object.pointer_id == pointer_id
      ap_id = ap_activity.object.data["id"]

      # Check that the cachex keys exist (true = present in cache, false = would hit DB)
      key_pointer = ActivityPub.Utils.ap_cache_key(:pointer, pointer_id)
      key_ap_id = ActivityPub.Utils.ap_cache_key(:ap_id, ap_id)

      assert {:ok, true} = Cachex.exists?(:ap_object_cache, key_pointer)
      assert {:ok, true} = Cachex.exists?(:ap_object_cache, key_ap_id)

      # Double check via get_cached (should hit cache or DB)
      assert {:ok, _object} = ActivityPub.Object.get_cached(pointer: pointer_id)
      assert {:ok, _object} = ActivityPub.Object.get_cached(ap_id: ap_id)
    end
  end
end
