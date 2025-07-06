defmodule Bonfire.Federate.ActivityPub.PostWebTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Common.Repo
  import Tesla.Mock
  import Untangle
  alias Bonfire.Posts
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      # %{method: :get, url: "https://mocked.local/users/karen"} ->
      #   json(Simulate.actor_json("https://mocked.local/users/karen"))

      # %{method: :get, url: "https://mocked.local/users/karen/statuses/114800379424129152/activity"} ->
      # "../fixtures/mastodon-post-activity-with-cw.json"
      # |> Path.expand(__DIR__)
      # |> File.read!()
      # |> json()
      # # |> Jason.decode!()

      _ ->
        raise Tesla.Mock.Error, "Module request not mocked"
    end)
    |> debug("setup done")

    :ok
  end

  describe "can" do
    test "fetch local post from AP API with Pointer ID, and take into account unindexable setting" do
      user =
        fake_user!()

      # |> debug("a user")

      user =
        current_user(
          Bonfire.Common.Settings.put([Bonfire.Search.Indexer, :modularity], :disabled,
            current_user: user
          )
        )

      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      obj =
        build_conn()
        |> get("/pub/objects/#{post.id}")
        |> response(200)
        # |> debug
        |> Jason.decode!()

      assert obj["content"] =~ attrs.post_content.html_body
      assert obj["indexable"] == false
    end

    test "fetch local post from AP API with AP ID" do
      user = fake_user!()
      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      id = ap_activity.object.data["id"]

      obj =
        build_conn()
        |> get(id)
        |> response(200)
        |> Jason.decode!()

      assert obj["content"] =~ attrs.post_content.html_body
    end

    test "fetch local post from AP API with friendly URL and Accept header" do
      user = fake_user!()
      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert build_conn()
             |> put_req_header("accept", "application/activity+json")
             |> get("/post/#{post.id}")
             |> redirected_to() =~ "/pub/objects/#{post.id}"
    end

    test "process mastodon activity with content warning" do
      # url = "https://mocked.local/users/karen/statuses/114800379424129152/activity"

      data =
        "../fixtures/mastodon-post-activity.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      # |> debug("pxxx")

      {:ok, data} =
        data
        |> Map.update("object", %{}, fn object ->
          object
          # ensure sensitive is set to true
          |> Map.put("sensitive", true)
          |> Map.put("summary", "politics")
        end)
        |> ActivityPub.Federator.Transformer.handle_incoming()

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :sensitive])

      assert post.__struct__ == Bonfire.Data.Social.Post
      assert is_binary(e(post, :post_content, :html_body, nil))

      # Check that content warning/summary is preserved
      s = e(post, :post_content, :summary, nil)
      assert is_binary(s) and s != ""

      # Post should be marked as sensitive when it has a content warning
      assert post.sensitive.is_sensitive == true
    end

    test "process mastodon Update activity with content warning should preserve CW" do
      # First, create the original post without CW
      original_data =
        "../fixtures/mastodon-post-activity.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, original} = ActivityPub.Federator.Transformer.handle_incoming(original_data)

      assert {:ok, original_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(original)
               |> repo().maybe_preload([:post_content, :sensitive])

      # Verify original post has no CW
      assert is_nil(e(original_post, :post_content, :summary, nil)) or
               e(original_post, :post_content, :summary, nil) == ""

      assert original_post.sensitive.is_sensitive == false

      # Now process an Update activity that adds a content warning
      {:ok, update_data} =
        original_data
        # Ensure this is an Update activity
        |> Map.put("type", "Update")
        |> Map.update("object", %{}, fn object ->
          object
          |> Map.put("sensitive", true)
          |> Map.put("summary", "politics")
        end)
        |> Map.update("id", %{}, fn id ->
          # needs a unique activity ID
          "#{id}/update"
        end)
        |> ActivityPub.Federator.Transformer.handle_incoming()

      assert {:ok, updated_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(update_data)
               |> repo().maybe_preload([:post_content, :sensitive])

      #  |> debug("received_update")

      # This should pass when the bug is fixed
      # Check that content warning/summary is preserved after update
      s = e(updated_post, :post_content, :summary, nil)
      assert is_binary(s) and s != "", "Content warning text should be added by Update activity"

      # Post should be marked as sensitive when CW is added via Update
      assert updated_post.sensitive.is_sensitive == true,
             "Post should be marked sensitive after Update with CW"
    end

    test "process mastodon Update activity changing content warning" do
      # First, create the original post WITH CW
      original_data =
        "../fixtures/mastodon-post-activity.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.update("object", %{}, fn object ->
          object
          |> Map.put("sensitive", true)
          |> Map.put("summary", "politics")
        end)

      {:ok, original} = ActivityPub.Federator.Transformer.handle_incoming(original_data)

      assert {:ok, original_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(original)
               |> repo().maybe_preload([:post_content, :sensitive])

      # Verify original post HAS a CW
      s = e(original_post, :post_content, :summary, nil)
      assert is_binary(s) and s != "", "Original post should have content warning"
      assert original_post.sensitive.is_sensitive == true

      # Now process an Update activity that removes the content warning
      {:ok, update_data} =
        original_data
        # Ensure this is an Update activity
        |> Map.put("type", "Update")
        |> Map.update("object", %{}, fn object ->
          object
          |> Map.put("sensitive", false)
          # Remove the summary/CW
          |> Map.delete("summary")
        end)
        |> Map.update("id", %{}, fn id ->
          # needs a unique activity ID
          "#{id}/update"
        end)
        |> ActivityPub.Federator.Transformer.handle_incoming()

      assert {:ok, updated_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(update_data)
               |> repo().maybe_preload([:post_content, :sensitive])

      #  |> debug("received_update")

      # Check that content warning/summary is removed after update
      s = e(updated_post, :post_content, :summary, nil)
      assert is_nil(s) or s == "", "Content warning should be removed in Update activity"

      # Post should no longer be marked as sensitive when CW is removed via Update
      assert e(updated_post, :sensitive, :is_sensitive, false) == false,
             "Post should not be marked sensitive after Update removes CW"
    end

    test "process mastodon Update activity with hashtag and mention changes" do
      # First, create the original post with existing hashtags
      original_data =
        "../fixtures/mastodon-post-activity.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, original} = ActivityPub.Federator.Transformer.handle_incoming(original_data)
      # |> debug("normalized")

      assert {:ok, original_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(original)
               |> repo().maybe_preload([:post_content, tags: [:named, :character]])

      # Verify original post has the fixture hashtags: #first_hashtag, #test, #tests
      original_hashtags =
        original_post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))
        |> Enum.sort()

      assert "first_hashtag" in original_hashtags
      assert "test" in original_hashtags
      assert "tests" in original_hashtags
      assert length(original_hashtags) == 3

      # Verify original post has no mentions
      original_mentions =
        original_post.tags
        |> Enum.filter(&(not is_nil(e(&1, :character, nil))))

      assert length(original_mentions) == 0

      # First Update: Add new hashtag, remove one, keep others, add mentions
      {:ok, update_data} =
        original_data
        |> Map.put("type", "Update")
        |> Map.update("object", %{}, fn object ->
          object
          |> Map.put("content", "Updated content with different hashtags and @karen mention")
          |> Map.put("tag", [
            # Keep #first_hashtag and #test, remove #tests
            %{
              "type" => "Hashtag",
              "name" => "#first_hashtag"
            },
            %{
              "type" => "Hashtag",
              "name" => "#test"
            },
            # Add new hashtag
            %{
              "type" => "Hashtag",
              "name" => "#elixir"
            },
            # Add mention
            %{
              "type" => "Mention",
              "href" => @remote_actor,
              "name" => "@karen"
            }
          ])
        end)
        |> Map.update("id", %{}, fn id ->
          # needs a unique activity ID
          "#{id}/update"
        end)
        |> ActivityPub.Federator.Transformer.handle_incoming()

      # |> debug("normalized")

      assert {:ok, updated_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(update_data)
               |> repo().maybe_preload([:post_content, tags: [:named, :character]])

      # Verify updated post has correct hashtags
      updated_hashtags =
        updated_post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))
        |> Enum.sort()

      # kept
      assert "first_hashtag" in updated_hashtags
      # kept
      assert "test" in updated_hashtags
      # added
      assert "elixir" in updated_hashtags
      # removed
      refute "tests" in updated_hashtags
      assert length(updated_hashtags) == 3

      # Verify updated post has correct mentions
      updated_mentions =
        updated_post.tags
        |> Enum.filter(&(not is_nil(e(&1, :character, nil))))

      assert length(updated_mentions) == 1

      # Second Update: Remove all hashtags but keep mentions, add new mention
      {:ok, second_update_data} =
        original_data
        |> Map.put("type", "Update")
        |> Map.update("object", %{}, fn object ->
          object
          |> Map.put("content", "Final update with no hashtags but @karen mention")
          |> Map.put("tag", [
            # Keep existing mention
            %{
              "type" => "Mention",
              "href" => @remote_actor,
              "name" => "@karen"
            }
            # Remove all hashtags
          ])
        end)
        |> Map.update("id", %{}, fn id ->
          # needs a unique activity ID
          "#{id}/update2"
        end)
        |> ActivityPub.Federator.Transformer.handle_incoming()

      assert {:ok, final_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(second_update_data)
               |> repo().maybe_preload([:post_content, tags: [:named, :character]])

      # Verify final post has no hashtags
      final_hashtags =
        final_post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))

      assert length(final_hashtags) == 0

      # Verify final post still has mentions
      final_mentions =
        final_post.tags
        |> Enum.filter(&(not is_nil(e(&1, :character, nil))))

      assert length(final_mentions) == 1

      # Verify content was updated
      assert final_post.post_content.html_body =~
               "Final update with no hashtags but @karen mention"
    end
  end
end
