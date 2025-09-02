defmodule Bonfire.Federate.ActivityPub.Dance.MigrationExportImportTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Graph.Import
  alias Bonfire.Posts
  alias Bonfire.Social.Boosts

  test "export and import user posts and boosts works between 2 instances", context do
    # Set up users
    local_user = context[:local][:user]
    remote_user = context[:remote][:user]

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

    # Create another post, back-dated to ensure original date is preserved
    {:ok, post2} =
      Posts.publish(
        current_user: local_user,
        post_id: Bonfire.Common.DatesTimes.generate_ulid(%Date{year: 2023, month: 1, day: 1}),
        post_attrs: %{post_content: %{html_body: "My second post with some content"}},
        boundary: "public"
      )

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
    other_user = fancy_fake_user!("OtherUser")

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

    # Parse the exported JSON to verify structure
    {:ok, outbox_data} = File.read(json_path) |> elem(1) |> Jason.decode()

    assert is_map(outbox_data)
    assert Map.has_key?(outbox_data, "orderedItems")
    activities = outbox_data["orderedItems"]

    # Should have at least 5 activities (4 Create, 1 Announce)
    assert length(activities) >= 5

    # Verify we have Create and Announce activities
    create_activities = Enum.filter(activities, &(&1["type"] == "Create"))
    announce_activities = Enum.filter(activities, &(&1["type"] == "Announce"))
    debug(announce_activities, "exported announce activities with dates")

    assert length(create_activities) >= 4
    assert length(announce_activities) >= 1

    # Get canonical URLs while on local instance
    post1_url = Bonfire.Common.URIs.canonical_url(post1)
    post2_url = Bonfire.Common.URIs.canonical_url(post2)
    mention_post_url = Bonfire.Common.URIs.canonical_url(mention_post)
    hashtag_post_url = Bonfire.Common.URIs.canonical_url(hashtag_post)
    other_post_url = Bonfire.Common.URIs.canonical_url(other_post)

    # Set up remote instance and import
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("import activities on remote instance"))

      # Import activities without federating the boosts
      assert %{ok: imported_count} =
               Import.import_from_json_file(:outbox, remote_user.id, json_path)
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

      # Check that the remote user has boosted the imported activities
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

      assert Enum.any?(
               content_texts,
               &(String.contains?(&1, "#test") || String.contains?(&1, "@testuser"))
             )

      # Verify that imported boosts preserve their original dates
      Logger.metadata(action: info("verify original dates are preserved"))

      # Check that the boost of post2 (from 2023-01-01) maintains its date
      post2_boost_date = Boosts.date_last_boosted(remote_user, remote_post2)
      assert post2_boost_date.year == 2023
      assert post2_boost_date.month == 1

      # Check that the boost of other_post (post from from 2023-02-02 but boost from 2024-03-03) maintains its date
      other_post_boost_date = Boosts.date_last_boosted(remote_user, remote_other_post)
      assert other_post_boost_date.year == 2024
      assert other_post_boost_date.month == 3
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
          "actor": "https://example.com/users/test",
          "object": {
            "type": "Note",
            "content": "Valid post structure, but does not actually exist"
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

      # Should still import the valid activities
      assert result.error == 3
    end)
  end
end
