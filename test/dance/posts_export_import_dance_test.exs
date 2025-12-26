defmodule Bonfire.Federate.ActivityPub.Dance.MigrationExportImportTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Import
  alias Bonfire.Posts
  alias Bonfire.Social.Boosts

  test "export and import user posts and boosts works between 2 instances", context do
    # Set up users
    local_user = context[:local][:user]
    remote_user = context[:remote][:user]
    other_user = fancy_fake_user!("OtherLocalUser")

    remote_ap_id =
      context[:remote][:canonical_url]

    assert {:ok, remote_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(remote_ap_id)

    # Create some posts and activities on local instance
    Logger.metadata(action: info("create posts on local instance"))

    # Create a regular post
    {:ok, post1} =
      Posts.publish(
        current_user: local_user,
        post_attrs: %{post_content: %{html_body: "My first post for migration test"}},
        boundary: "public"
      )

    # Create nested replies to post1 to test thread import
    {:ok, %{id: reply1_id}} =
      Posts.publish(
        current_user: other_user[:user],
        post_attrs: %{
          post_content: %{html_body: "This is a reply to my first post"},
          reply_to_id: post1.id
        },
        boundary: "public"
      )

    {:ok, %{id: _reply2_id}} =
      Posts.publish(
        current_user: other_user[:user],
        post_attrs: %{
          post_content: %{html_body: "This is a nested reply"},
          reply_to_id: reply1_id
        },
        boundary: "public"
      )

    {:ok, %{id: _another_reply_id}} =
      Posts.publish(
        current_user: other_user[:user],
        post_attrs: %{
          post_content: %{html_body: "Another reply to the original post"},
          reply_to_id: post1.id
        },
        boundary: "public"
      )

    # Create another post, back-dated to ensure original date is preserved
    {:ok, post2} =
      Posts.publish(
        current_user: local_user,
        post_id: Bonfire.Common.DatesTimes.generate_ulid(%Date{year: 2023, month: 1, day: 1}),
        post_attrs: %{post_content: %{html_body: "My second post with outdated content"}},
        boundary: "public"
      )

    # Verify that post2's creation date was preserved
    post2_creation_date = Bonfire.Common.DatesTimes.date_from_pointer(post2.id)
    assert post2_creation_date.year == 2023
    assert post2_creation_date.month == 1

    # Create post with mentions
    {:ok, mention_post} =
      Posts.publish(
        current_user: local_user,
        post_attrs: %{post_content: %{html_body: "Hello @testuser how are you?"}},
        boundary: "public"
      )

    # Create post with hashtags
    {:ok, hashtag_post} =
      Posts.publish(
        current_user: local_user,
        post_attrs: %{post_content: %{html_body: "This is a #test post with #hashtags"}},
        boundary: "public"
      )

    # Create a boost of another user's post
    {:ok, other_post} =
      Posts.publish(
        current_user: other_user[:user],
        post_id: Bonfire.Common.DatesTimes.generate_ulid(%Date{year: 2023, month: 2, day: 2}),
        post_attrs: %{post_content: %{html_body: "A post to be boosted"}},
        boundary: "public"
      )

    # Boost back-dated to ensure the boost date is preserved (not the post creation date)
    {:ok, _boost} =
      Boosts.boost(local_user, other_post,
        pointer_id: Bonfire.Common.DatesTimes.generate_ulid(%Date{year: 2024, month: 3, day: 3})
      )

    other_post_boost_date = Boosts.date_last_boosted(local_user, other_post)
    assert other_post_boost_date.year == 2024
    assert other_post_boost_date.month == 3

    # Export user's outbox to JSON
    Logger.metadata(action: info("export outbox via controller"))
    json_path = "/tmp/test_outbox_export.json"

    # Create a test connection and call the export endpoint
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:current_user, local_user)
      |> get("/settings/export/json/outbox")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    # Write the response body to file
    File.write!(json_path, conn.resp_body)

    # Parse and modify the exported JSON to test embedded object insertion
    assert {:ok, %{} = outbox_data} = File.read(json_path) |> elem(1) |> Jason.decode()
    assert Map.has_key?(outbox_data, "orderedItems")
    activities = outbox_data["orderedItems"]
    assert length(activities) >= 5
    # Verify we have Create and Announce activities
    create_activities = Enum.filter(activities, &(&1["type"] == "Create"))
    announce_activities = Enum.filter(activities, &(&1["type"] == "Announce"))
    debug(announce_activities, "exported announce activities with dates")

    assert length(create_activities) >= 4
    assert length(announce_activities) >= 1

    # Find and modify post2's content in the exported activities
    modified_content =
      "MODIFIED: This content was changed in the exported JSON to verify embedded objects are used"

    modified_activities =
      Enum.map(activities, fn activity ->
        if activity["type"] == "Create" do
          cond do
            get_in(activity, ["object", "content"]) =~ "My first post for migration test" ->
              # make this activity not be embedded to test fetching fallback
              put_in(activity, ["object"], get_in(activity, ["object", "id"]))

            get_in(activity, ["object", "content"]) =~ "My second post with outdated content" ->
              put_in(activity, ["object", "content"], modified_content)

            true ->
              nil
          end
        end || activity
      end)

    outbox_data = Map.put(outbox_data, "orderedItems", modified_activities)

    # Assert that the modifications worked

    assert Enum.any?(outbox_data["orderedItems"], fn activity ->
             activity["type"] == "Create" and
               e(activity, "object", "content", nil) == modified_content
           end),
           "Should have found the modified content in the exported JSON before import"

    assert Enum.any?(outbox_data["orderedItems"], fn activity ->
             activity["type"] == "Create" and
               is_binary(get_in(activity, ["object"]))
           end),
           "Should have found the modified non-embedded object in the exported JSON before import"

    # Write the modified JSON back (NOTE: should not be necessary if we just use outbox_data directly)
    # File.write!(json_path, Jason.encode!(modified_outbox))
    # Parse the exported JSON to verify structure
    # {:ok, outbox_data} = File.read(json_path) |> elem(1) |> Jason.decode()

    # Get canonical URLs while on local instance
    post1_url = Bonfire.Common.URIs.canonical_url(post1)
    post2_url = Bonfire.Common.URIs.canonical_url(post2)
    mention_post_url = Bonfire.Common.URIs.canonical_url(mention_post)
    hashtag_post_url = Bonfire.Common.URIs.canonical_url(hashtag_post)
    other_post_url = Bonfire.Common.URIs.canonical_url(other_post)
    # reply1_url = Bonfire.Common.URIs.canonical_url(reply1)
    # reply2_url = Bonfire.Common.URIs.canonical_url(reply2)
    # another_reply_url = Bonfire.Common.URIs.canonical_url(another_reply)

    # Set up remote instance and import
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("import activities on remote instance"))

      # specify we want to fetch replies too
      remote_user =
        current_user(
          Settings.put([Bonfire.Social.Import, :fetch_threads_on_import], true,
            current_user: remote_user
          )
        )

      # Import activities without federating the boosts
      assert %{ok: imported_count} =
               Import.import_from_json(:outbox, remote_user, outbox_data, include_boosts: true)
               |> debug("import_result")

      # Clean up
      File.rm(json_path)

      assert imported_count >= 5

      # Verify the imported activities exist in remote user's feed
      Logger.metadata(action: info("verify imported activities"))

      # Get the post structs on remote instance using their canonical URLs
      {:ok, remote_post1} = AdapterUtils.get_or_fetch_and_create_by_uri(post1_url)
      {:ok, remote_post2} = AdapterUtils.get_or_fetch_and_create_by_uri(post2_url)
      {:ok, remote_mention_post} = AdapterUtils.get_or_fetch_and_create_by_uri(mention_post_url)
      {:ok, remote_hashtag_post} = AdapterUtils.get_or_fetch_and_create_by_uri(hashtag_post_url)
      {:ok, remote_other_post} = AdapterUtils.get_or_fetch_and_create_by_uri(other_post_url)

      # Check that the remote user has boosted the imported activities (their own posts/activities)
      assert Boosts.boosted?(remote_user, remote_post1)
      assert Boosts.boosted?(remote_user, remote_post2)
      assert Boosts.boosted?(remote_user, remote_mention_post)
      assert Boosts.boosted?(remote_user, remote_hashtag_post)
      assert Boosts.boosted?(remote_user, remote_other_post)

      # Verify they appear in new user's outbox and original content is preserved in the boosted activities
      %{edges: user_feed} =
        Bonfire.Social.FeedLoader.feed(:user_activities,
          current_user: remote_user,
          by: remote_user,
          limit: 20,
          preload: [:with_post_content]
        )

      assert is_binary(List.first(user_feed).activity.object.post_content.html_body)

      # Verify content preservation - check that hashtags and mentions are preserved
      content_texts =
        Enum.map(user_feed, fn %{activity: activity} ->
          activity.object && activity.object.post_content &&
            activity.object.post_content.html_body
        end)
        |> Enum.filter(&is_binary/1)

      # Verify the content, including the modified content from the JSON was imported (proving embedded objects are used)
      assert Enum.all?(
               content_texts,
               &String.contains?(&1, [
                 "#test",
                 "@testuser",
                 "My first post for migration test",
                 "A post to be boosted",
                 "MODIFIED: This content was changed in the exported JSON"
               ])
             )

      # Verify that imported boosts preserve their original dates
      Logger.metadata(action: info("verify original dates are preserved"))

      # Verify that post2's creation date was preserved
      post2_creation_date = Bonfire.Common.DatesTimes.date_from_pointer(remote_post2.id)
      assert post2_creation_date.year == 2023
      assert post2_creation_date.month == 1

      # Check that the boost of post2 (from 2023-01-01) maintains its date as well
      post2_boost_date = Boosts.date_last_boosted(remote_user, remote_post2)
      assert post2_boost_date.year == 2023
      assert post2_boost_date.month == 1

      # Check that the boost of other_post (post from from 2023-02-02 but boost from 2024-03-03) maintains its date
      post_creation_date = Bonfire.Common.DatesTimes.date_from_pointer(remote_other_post.id)
      assert post_creation_date.year == 2023
      assert post_creation_date.month == 2
      other_post_boost_date = Boosts.date_last_boosted(remote_user, remote_other_post)
      assert other_post_boost_date.year == 2024
      assert other_post_boost_date.month == 3

      Logger.metadata(action: info("verify reply thread is pulled in"))

      %{edges: feed} =
        Bonfire.Social.FeedLoader.feed(:explore,
          current_user: remote_user,
          limit: 100,
          preload: [:with_post_content]
        )

      assert Bonfire.Social.FeedLoader.feed_contains?(
               feed,
               "This is a reply to my first post",
               current_user: remote_user
             ),
             "Reply1 content should be available in feed"

      assert Bonfire.Social.FeedLoader.feed_contains?(feed, "This is a nested reply",
               current_user: remote_user
             ),
             "Reply2 content should be available in feed"

      assert Bonfire.Social.FeedLoader.feed_contains?(
               feed,
               "Another reply to the original post",
               current_user: remote_user
             ),
             "Another_reply content should be available in feed"
    end)

    # Verify boosts were not federated (check that remote_user did not boost other_post from local instance perspective)
    Logger.metadata(action: info("verify boosts were not federated back"))

    refute Boosts.boosted?(remote_on_local, post1),
           "Remote user should not appear to have boosted post1 from local instance perspective"

    refute Boosts.boosted?(remote_on_local, other_post),
           "Remote user should not appear to have boosted other_post from local instance perspective"
  end

  test "import gracefully ignores malformed or unsupported activities", context do
    remote_user = context[:remote][:user]

    # Create a malformed JSON file
    malformed_json = """
    {
      "type": "OrderedCollection",
      "orderedItems": [
        {
          "type": "Create",
          "id": "https://example.com/activity/id1",
          "actor": "https://example.com/users/test",
          "object": {
            "id": "https://example.com/post/id1",
            "type": "Note",
            "content": "Valid post structure, but does not actually exist"
          }
        },
        {
          "type": "Boost",
          "actor": "https://example.com/users/test",
          "object": {
            "type": "Note",
            "content": "Boosted post should simply be ignored"
          }
        },
        {
          "type": "UnsupportedActivity",
          "actor": "https://example.com/users/test"
        },
        {
          "invalid": "json structure"
        }
      ]
    }
    """

    json_path = "/tmp/test_malformed_outbox.json"
    File.write!(json_path, malformed_json)

    TestInstanceRepo.apply(fn ->
      # Should handle errors gracefully and import what it can
      result = Import.import_from_json_file(:outbox, remote_user.id, json_path)

      # Clean up
      File.rm(json_path)

      assert result.error == 1
      assert result.ok == 3
    end)
  end
end
