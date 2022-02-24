defmodule Bonfire.Federate.ActivityPub.Boundaries.SilenceFeedsInstanceWideTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias ActivityPub.Config
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Data.ActivityPub.Peered

  @remote_actor "https://kawen.space/users/karen"

  setup do
    orig = Config.get!(:boundaries)

    Config.put(:boundaries,
      block: [],
      silence: [],
      ghost: []
    )

    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    on_exit(fn ->
      Config.put(:boundaries, orig)
    end)
  end


  defp build_remote_activity(actor, recipient_actor) do
    context = "blabla"

    object = %{
      "content" => "content",
      "type" => "Note",
      "to" => [
        recipient_actor.ap_id,
        "https://www.w3.org/ns/activitystreams#Public"
      ]
    }

    to = [
      recipient_actor.ap_id,
      "https://www.w3.org/ns/activitystreams#Public"
    ]

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to
    }
  end

  def prepare_remote_post_for(recipient) do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient_actor = ActivityPub.Actor.get_by_local_id!(recipient.id)
    params = build_remote_activity(actor, recipient_actor)
    with {:ok, activity} <- ActivityPub.create(params), do:
      assert {:ok, post} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
  end

  test "creates a Post for an incoming Note with no silencing" do
    recipient = fake_user!()
    prepare_remote_post_for(recipient)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    #|> debug()
    assert %{edges: [feed_entry]} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

  test "does not create a Post for an incoming Note with silenced instance" do
    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      # |> debug
      |> Bonfire.Boundaries.block(:silence, :instance_wide)

    recipient = fake_user!()
    prepare_remote_post_for(recipient)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

  test "does not create a Post for an incoming Note with silenced actor" do
    {:ok, remote_user} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    assert {:ok, user} = Bonfire.Me.Users.by_username(remote_user.username)
    Bonfire.Boundaries.block(user, :silence, :instance_wide)

    recipient = fake_user!()
    prepare_remote_post_for(recipient)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

  test "hides a Post in feed from a remote instance that was silenced later" do

    recipient = fake_user!()
    prepare_remote_post_for(recipient)

    Bonfire.Federate.ActivityPub.Instances.get_or_create(@remote_actor)
      # |> debug
      |> Bonfire.Boundaries.block(:silence, :instance_wide)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    assert %{edges: []} = Bonfire.Social.FeedActivities.feed(feed_id, recipient)
  end

end
