defmodule Bonfire.Federate.ActivityPub.HashtagHandlingTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  import Untangle

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @remote_actor <> "/followers"} ->
        json(%{})

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  describe "outgoing hashtag handling" do
    test "trailing hashtags on bottom line are stripped from html_body content" do
      user = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{
              html_body: "This is a post about data protection.\n#privacy #gdpr"
            }
          },
          boundary: "public"
        )

      post = repo().maybe_preload(post, [:post_content, tags: [:named, :character]])

      # The main content should be preserved
      assert post.post_content.html_body =~ "data protection"

      # The trailing hashtags should be stripped from inline content
      refute post.post_content.html_body =~ "#privacy"
      refute post.post_content.html_body =~ "#gdpr"

      # But the hashtags should still be associated via tags
      hashtag_names =
        post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "privacy" in hashtag_names
      assert "gdpr" in hashtag_names
    end
  end

  describe "incoming hashtag handling" do
    test "pixelfed ?src=hash hashtag links get rewritten to local" do
      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, tags: [:named, :character]])

      # Hashtag links should be rewritten to local /hashtag/ paths (with IDs)
      assert post.post_content.html_body =~ ~r|/hashtag/[A-Z0-9]+.*#collage|
      assert post.post_content.html_body =~ ~r|/hashtag/[A-Z0-9]+.*#art|

      # Should NOT contain the original pixelfed URLs
      refute post.post_content.html_body =~ "pixelfed.local/discover/tags"
      refute post.post_content.html_body =~ "?src=hash"

      # Hashtags should be associated via tags
      hashtag_names =
        post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "collage" in hashtag_names
      assert "art" in hashtag_names
    end

    test "trailing hashtag paragraph is stripped from content" do
      data =
        "../fixtures/mastodon-post-activity-trailing-hashtags.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} =
        ActivityPub.Federator.Transformer.handle_incoming(data, fetch_collection: false)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, tags: [:named, :character]])

      # The main content should be preserved
      assert post.post_content.html_body =~ "age verification"

      # The trailing hashtag paragraph should be stripped from the body
      # (Mastodon wraps names in <span>, so check for the word itself)
      refute post.post_content.html_body =~ "privacy"
      refute post.post_content.html_body =~ "gdpr"

      # But the hashtags should still be associated via tags
      hashtag_names =
        post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "privacy" in hashtag_names
      assert "gdpr" in hashtag_names
    end

    test "out-of-band hashtags are associated but not in content" do
      data =
        "../fixtures/mastodon-post-activity.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} =
        ActivityPub.Federator.Transformer.handle_incoming(data, fetch_collection: false)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, tags: [:named, :character]])

      hashtag_names =
        post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      # #tests is in the tag array but NOT in the content text
      assert "tests" in hashtag_names

      # It should not appear in the html body
      refute post.post_content.html_body =~ "#tests"

      # The in-band hashtags should still be present
      assert "first_hashtag" in hashtag_names
      assert "test" in hashtag_names
    end
  end
end
