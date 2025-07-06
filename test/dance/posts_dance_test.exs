defmodule Bonfire.Federate.ActivityPub.Dance.PostsTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.PostContents
  alias Bonfire.Social.Graph.Follows

  @tag :test_instance
  test "can make a public post, and fetch it from AP API (both with AP ID and with friendly URL and Accept header)",
       context do
    user = context[:local][:user]

    Logger.metadata(action: "create local post 1")
    attrs = %{post_content: %{html_body: "test content one"}}
    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post)
      |> info("canonical_url")

    Logger.metadata(action: "create local post 2")
    attrs2 = %{post_content: %{html_body: "test content two"}}
    {:ok, post2} = Posts.publish(current_user: user, post_attrs: attrs2, boundary: "public")

    friendly_url =
      (Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(post2))
      |> info("friendly_url")

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch post 1 by canonical_url")

      assert {:ok, object} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload(:post_content)

      assert object.post_content.html_body =~ attrs.post_content.html_body

      Logger.metadata(action: "fetch post 2 by friendly_url")

      assert {:ok, object2} =
               AdapterUtils.get_by_url_ap_id_or_username(friendly_url)
               |> repo().maybe_preload(:post_content)

      assert object2.post_content.html_body =~ attrs2.post_content.html_body
    end)
  end

  @tag :test_instance
  test "a local-only or private post cannot be fetched from AP API",
       context do
    user = context[:local][:user]

    Logger.metadata(action: "create local-only post 1")
    attrs = %{post_content: %{html_body: "local-only post 1"}}
    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "local")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post)
      |> info("canonical_url")

    Logger.metadata(action: "create private post 2")
    attrs2 = %{post_content: %{html_body: "private post 2"}}
    {:ok, post2} = Posts.publish(current_user: user, post_attrs: attrs2, boundary: "mentions")

    friendly_url =
      (Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(post2))
      |> info("friendly_url")

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch post 1 by canonical_url")

      assert {:error, :not_found} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload(:post_content)

      Logger.metadata(action: "fetch post 2 by friendly_url")

      assert {:error, :not_found} =
               AdapterUtils.get_by_url_ap_id_or_username(friendly_url)
               |> repo().maybe_preload(:post_content)
    end)
  end

  test "can federate edits",
       context do
    user = context[:local][:user]
    local2 = fancy_fake_user!("Local2")
    user2 = local2[:user]

    Logger.metadata(action: "create local post 1")
    attrs = %{post_content: %{html_body: "test content one"}}
    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post)
      |> info("canonical_url")

    Logger.metadata(action: "create local post 2")
    attrs2 = %{post_content: %{html_body: "test content two"}}
    {:ok, post2} = Posts.publish(current_user: user2, post_attrs: attrs2, boundary: "public")

    friendly_url =
      (Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(post2))
      |> info("friendly_url")

    # then we fetch both so they're cached on the remote
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "follow user1 to see if we automatically get the edit")

      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])

      remote_follower = context[:remote][:user]
      assert {:ok, follow} = Follows.follow(remote_follower, follower_on_remote)

      Logger.metadata(action: "fetch post 1 by canonical_url")

      assert {:ok, object} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload(:post_content)

      assert object.post_content.html_body =~ attrs.post_content.html_body

      Logger.metadata(action: "fetch post 2 by friendly_url")

      assert {:ok, object2} =
               AdapterUtils.get_by_url_ap_id_or_username(friendly_url)
               |> repo().maybe_preload(:post_content)

      assert object2.post_content.html_body =~ attrs2.post_content.html_body
    end)

    # back to local
    Logger.metadata(action: "edit post1")
    assert {:ok, _} = Bonfire.Social.PostContents.edit(user, id(post), %{html_body: "edited 1"})

    Logger.metadata(action: "edit post2")
    assert {:ok, _} = Bonfire.Social.PostContents.edit(user2, id(post2), %{html_body: "edited 2"})

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "check edit of post 1 was federated to follower")

      assert {:ok, object} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload(:post_content)

      assert object.post_content.html_body =~ "edited 1"

      Logger.metadata(action: "fetch post 2 again (or use from cache)")

      assert {:ok, object2} =
               AdapterUtils.get_by_url_ap_id_or_username(friendly_url)
               |> repo().maybe_preload(:post_content)

      refute object2.post_content.html_body =~ "edited 2"
      # TODO: find a way to get these edits too?
    end)
  end

  @tag :test_instance
  test "handles requests with non-standard Accept headers gracefully",
       context do
    user = context[:local][:user]

    Logger.metadata(action: "create public post")
    attrs = %{post_content: %{html_body: "test content for bot request"}}
    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post)
      |> info("canonical_url")

    # Simulate a bot request with HTML-only Accept headers
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "test fetch with unsupported Accept header")

      # First verify the post exists and can be properly accessed with ActivityPub compatible headers
      assert {:ok, _object} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload(:post_content)

      # Now test the actual HTTP request with bot-like headers
      # Use the existing HTTP client in TestInstanceRepo to make a request
      # with headers similar to what a bot would send
      Logger.metadata(action: "simulate bot request with HTML Accept header")

      # Use TestInstanceRepo's HTTP client to make a request with bot-like headers
      case ActivityPub.Federator.HTTP.get(
             canonical_url,
             [
               {"accept",
                "text/html, application/rss+xml, application/atom+xml, text/xml, text/rss+xml, application/xhtml+xml"},
               {"user-agent", "Mozilla/5.0 (compatible; SomeBot/1.0; +http://example.com/bot)"}
             ]
           ) do
        # We want this to succeed with some appropriate response
        # not crash with Phoenix.NotAcceptableError
        {:ok, %{status: status, body: body}} ->
          # The status should be a valid HTTP status (likely 200 OK)
          # and not crash the application
          assert status in 200..299
          # We should get some kind of valid response, even if it's
          # a simplified representation or a redirect
          assert is_binary(body)

        {:error, error} ->
          # If there is an error, it shouldn't be a crash
          # but a proper error handling
          refute error == :not_acceptable
          refute is_exception(error)
      end
    end)
  end

  @tag :test_instance
  test "incoming CW on remote posts is recognised",
       context do
    local_user = context[:local][:user]

    Logger.metadata(action: "create post with CW and summary")

    attrs_with_summary = %{
      sensitive: true,
      post_content: %{
        html_body: "This is sensitive content that should be hidden",
        summary: "Content Warning: Sensitive Topic"
      }
    }

    {:ok, post_with_summary} =
      Posts.publish(current_user: local_user, post_attrs: attrs_with_summary, boundary: "public")

    Logger.metadata(action: "create post with CW but no summary")

    attrs_no_summary = %{
      sensitive: true,
      post_content: %{
        html_body: "Another sensitive post without explicit summary"
      }
    }

    {:ok, post_no_summary} =
      Posts.publish(current_user: local_user, post_attrs: attrs_no_summary, boundary: "public")

    canonical_url_with_summary = Bonfire.Common.URIs.canonical_url(post_with_summary)
    canonical_url_no_summary = Bonfire.Common.URIs.canonical_url(post_no_summary)

    # Back to local instance to verify CW recognition
    Logger.metadata(action: "verify CW posts are properly imported on remote instance")

    # Get the remote posts' URLs
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch remote CW posts on remote instance")

      assert {:ok, fetched_post_with_summary} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url_with_summary)
               |> repo().maybe_preload(:post_content)

      assert {:ok, fetched_post_no_summary} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url_no_summary)
               |> repo().maybe_preload(:post_content)

      assert fetched_post_with_summary.post_content.summary == "Content Warning: Sensitive Topic"

      assert fetched_post_with_summary.post_content.html_body =~
               "This is sensitive content that should be hidden"

      assert fetched_post_with_summary.sensitive.is_sensitive == true

      assert fetched_post_no_summary.post_content.html_body =~
               "Another sensitive post without explicit summary"

      assert fetched_post_no_summary.sensitive.is_sensitive == true
    end)
  end
end
