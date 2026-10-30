defmodule Bonfire.Federate.ActivityPub.MessageIntegrationTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Messages

  import Tesla.Mock

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{
        method: :get,
        url: "https://mocked.local/.well-known/nodeinfo"
      } ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  describe "" do
    test "messages get queued to federate" do
      me = fake_user!()
      messaged = fake_user!()

      msg = "hey you have an epic text message"
      attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}

      assert {:ok, message} = Messages.send(me, attrs)

      ap_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(message)
      assert %{__struct__: ActivityPub.Object} = ap_activity

      Oban.Testing.assert_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.PublisherWorker,
        args: %{"op" => "publish", "activity_id" => ap_activity.id, "repo" => repo()}
      )
    end

    test "can federate message" do
      me = fake_user!()
      messaged = fake_user!()
      msg = "hey you have an epic text message"
      attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}
      assert {:ok, message} = Messages.send(me, attrs)

      {:ok, activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(message)

      assert activity.object.data["content"] =~ msg
    end

    test "can receive federated ChatMessage" do
      me = fake_user!()
      {:ok, local_actor} = ActivityPub.Actor.get_cached(pointer: me.id)
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      context = "blabla"

      object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "content" => "content",
        "type" => "ChatMessage"
      }

      to = [local_actor.ap_id]

      params = %{
        actor: actor,
        context: context,
        object: object,
        to: to
      }

      {:ok, activity} = ActivityPub.create(params)

      # the ONLY application here: these params leave `local` at its default (true), so `ActivityPub.create/1` stored it as ours and skipped the adapter
      assert {:ok, %Bonfire.Data.Social.Message{} = message} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
    end

    test "creates a Message for an incoming private Note with @ mention" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      params =
        remote_activity_json_with_mentions(actor, recipient_actor)
        |> debug("json!")

      {:ok, activity} = ActivityPub.create(params)

      assert actor.data["id"] == activity.data["actor"]
      assert params.object["content"] == activity.object.data["content"]

      assert {:ok, %Bonfire.Data.Social.Message{} = message} =
               {:ok, activity.pointer}
               |> repo().maybe_preload(:post_content)

      assert message.post_content.html_body =~ params.object["content"]

      assert %{edges: feed} = Messages.list(recipient)
      assert List.first(feed).id == message.id

      refute =
        Bonfire.Social.FeedLoader.feed_contains?(:remote, message, current_user: recipient)
    end

    # Not a `Message`: a message names its recipients, so the moderators would see each other and a reply would show them. It is a private post that mentions the bot, which the moderators are given read access to without being tagged.
    test "a private Note to the instance's federation bot is a post readable by whoever can moderate the instance, who are notified, and by nobody else" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, bot} = Bonfire.Federate.ActivityPub.Adapter.get_or_create_service_actor()
      moderator = Bonfire.Me.Fake.instance_moderator!(fake_user!())
      {:ok, admin} = Bonfire.Me.Users.make_admin(fake_user!())
      someone_else = fake_user!()

      params = remote_activity_json_with_mentions(actor, bot)
      {:ok, activity} = ActivityPub.create(params)

      assert %Bonfire.Data.Social.Post{id: post_id} = post = activity.pointer

      for staff <- [moderator, admin] do
        assert {:ok, _} = Bonfire.Posts.read(post_id, current_user: staff)

        assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post, current_user: staff)
      end

      assert {:error, _} = Bonfire.Posts.read(post_id, current_user: someone_else)
    end

    test "a public Note that mentions the instance's federation bot is in the notifications of whoever can moderate the instance, and in nobody else's" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, bot} = Bonfire.Federate.ActivityPub.Adapter.get_or_create_service_actor()
      moderator = Bonfire.Me.Fake.instance_moderator!(fake_user!())
      {:ok, admin} = Bonfire.Me.Users.make_admin(fake_user!())
      someone_else = fake_user!()

      params = remote_activity_json_with_mentions(actor, [bot, ActivityPub.Config.public_uri()])
      {:ok, activity} = ActivityPub.create(params)
      post = activity.pointer

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
               current_user: moderator
             )

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post, current_user: admin)

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, post,
               current_user: someone_else
             )
    end

    # A message to the bot is turned into a private post that mentions it, as an incoming one is, so that the moderators it is for are not named on it as recipients.
    test "a message a local user sends to the instance's federation bot is a private post readable by whoever can moderate the instance, who are notified, and by nobody else" do
      me = fake_user!()
      someone = fake_user!()
      bot = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_create_service_character()
      moderator = Bonfire.Me.Fake.instance_moderator!(fake_user!())
      {:ok, admin} = Bonfire.Me.Users.make_admin(fake_user!())

      # prove the positive first: a message to an ordinary user is still a message
      assert {:ok, %Bonfire.Data.Social.Message{}} =
               Messages.send(me, %{to_circles: [someone.id], post_content: %{html_body: "hi"}})

      assert {:ok, %Bonfire.Data.Social.Post{id: post_id} = post} =
               Messages.send(me, %{to_circles: [bot.id], post_content: %{html_body: "hello bot"}})

      for staff <- [moderator, admin] do
        assert {:ok, _} = Bonfire.Posts.read(post_id, current_user: staff)

        assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, post, current_user: staff)
      end

      assert {:error, _} = Bonfire.Posts.read(post_id, current_user: fake_user!())

      tagged =
        repo().all(
          Ecto.Query.from(t in Bonfire.Tag.Tagged, where: t.id == ^post_id, select: t.tag_id)
        )

      assert bot.id in tagged
      refute moderator.id in tagged
      refute admin.id in tagged
    end

    test "rejects a Message for an incoming private Note for a user with federation disabled" do
      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

      recipient = fake_user!()

      recipient =
        Bonfire.Federate.ActivityPub.disable(recipient)
        ~> current_user()

      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      params =
        remote_activity_json_with_mentions(actor, recipient_actor)
        |> info("json!")

      {:error, _} = ActivityPub.create(params)
    end
  end
end
