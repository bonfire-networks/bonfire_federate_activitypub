defmodule Bonfire.Federate.ActivityPub.Dance.FetchCollectionsTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Common.PubSub
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Feeds
  alias ActivityPub.Federator.Fetcher

  test "fetch_outbox syncs remote posts and they are received via PubSub",
       context do
    local_user = context[:local][:user]
    remote_user = context[:remote][:user]
    remote_ap_id = context[:remote][:canonical_url]

    post_content_1 = "outbox dance post one"
    post_content_2 = "outbox dance post two"

    # Remote: create 2 public posts
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("create remote posts"))

      {:ok, _post1} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: %{post_content: %{html_body: post_content_1}},
          boundary: "public"
        )

      {:ok, _post2} =
        Posts.publish(
          current_user: remote_user,
          post_attrs: %{post_content: %{html_body: post_content_2}},
          boundary: "public"
        )
    end)

    # Local: fetch the remote user so they exist locally
    Logger.metadata(action: info("fetch remote user locally"))

    assert {:ok, remote_user_local} =
             AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    # Local: subscribe to the fediverse feed for PubSub notifications — ALL of the remote feed ids,
    # not just the legacy `:activity_pub` one: with write-addressing on (the default since
    # `config/test.exs` declares it) incoming remote content is published to the `:remote_public`
    # bucket instead, so subscribing to the single legacy id would never receive it
    :ok = PubSub.subscribe(Feeds.named_feed_ids(:remote), current_user: local_user)

    # Local: fetch the remote user's outbox (async mode, runs inline in tests)
    Logger.metadata(action: info("fetch_outbox"))

    Fetcher.fetch_outbox(
      [pointer: remote_user_local],
      mode: :async,
      fetch_collection: true,
      fetch_collection_entries: :async,
      triggered_by: "dance_test:fetch_outbox"
    )

    # Assert: both activities arrive via PubSub
    assert_receive {
                     {Bonfire.Social.Feeds, :new_activity},
                     [feed_ids: _, activity: _]
                   },
                   15_000

    assert_receive {
                     {Bonfire.Social.Feeds, :new_activity},
                     [feed_ids: _, activity: _]
                   },
                   15_000
  end

  # what "Get latest activities" on a mirrored group's page does: the same fetch, for a group hosted on the other instance
  test "fetch_outbox of a remote group files its posts in our mirror of the group", context do
    creator = context[:remote][:user]

    {remote_group_url, post_urls} =
      TestInstanceRepo.apply(fn ->
        group = Bonfire.Classify.Simulate.fake_group!(creator, %{type: :group})

        :ok =
          Bonfire.Classify.Boundaries.replace(group, creator, %{
            membership: "open",
            visibility: "global",
            participation: "anyone",
            default_content_visibility: "public"
          })

        # the boundary stated, because `group` still holds the settings it was created with, from before `replace/3` stored the public default
        posts =
          for html <- ["<p>group outbox post one</p>", "<p>group outbox post two</p>"],
              do:
                Bonfire.Classify.Simulate.fake_post_in_group!(creator, group, html,
                  boundary: "public"
                )

        {Bonfire.Me.Characters.character_url(group),
         Enum.map(posts, &Bonfire.Common.URIs.canonical_url(&1, preload_if_needed: true))}
      end)

    assert {:ok, group} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_group_url)

    for url <- post_urls do
      refute match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: url)),
             "control: #{url} isn't here before the fetch"
    end

    # the same options as the button's handler (`Bonfire.Me.Users.LiveHandler`, "fetch_outbox")
    Fetcher.fetch_outbox([pointer: group],
      mode: :async,
      fetch_collection: :async,
      fetch_collection_entries: true,
      triggered_by: "dance_test:fetch_outbox"
    )

    for url <- post_urls do
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: url),
             "#{url} wasn't fetched"

      post = Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: group
             ),
             "#{url} should be filed in our mirror of the group"
    end
  end

  test "fetch_thread syncs remote replies and they are received via PubSub",
       context do
    local_user = context[:local][:user]
    remote_user = context[:remote][:user]

    root_content = "thread dance root post"
    reply_content = "thread dance reply"

    # Remote: create root post and a reply
    {root_url, _reply_url} =
      TestInstanceRepo.apply(fn ->
        Logger.metadata(action: info("create remote thread"))

        {:ok, root_post} =
          Posts.publish(
            current_user: remote_user,
            post_attrs: %{post_content: %{html_body: root_content}},
            boundary: "public"
          )

        {:ok, reply_post} =
          Posts.publish(
            current_user: remote_user,
            post_attrs: %{
              post_content: %{html_body: reply_content},
              reply_to: id(root_post)
            },
            boundary: "public"
          )

        {
          Bonfire.Common.URIs.canonical_url(root_post, preload_if_needed: true),
          Bonfire.Common.URIs.canonical_url(reply_post, preload_if_needed: true)
        }
      end)

    # Local: fetch the root post so it exists locally
    Logger.metadata(action: info("fetch root post locally"))

    assert {:ok, root_on_local} =
             AdapterUtils.get_by_url_ap_id_or_username(root_url)

    thread_id = id(root_on_local)

    # Local: subscribe to the thread for PubSub notifications
    :ok = PubSub.subscribe(thread_id, current_user: local_user)

    # Local: fetch the thread (async mode, runs inline in tests)
    Logger.metadata(action: info("fetch_thread"))

    Fetcher.fetch_thread(
      [pointer: thread_id],
      mode: :async,
      fetch_collection: true,
      fetch_collection_entries: :async,
      triggered_by: "dance_test:fetch_thread"
    )

    # Assert: reply arrives via PubSub as a thread notification
    assert_receive {
                     {Bonfire.Social.Threads.LiveHandler, :new_reply},
                     {^thread_id, _reply}
                   },
                   15_000
  end
end
