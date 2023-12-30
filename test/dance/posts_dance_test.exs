defmodule Bonfire.Federate.ActivityPub.Dance.PostsTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

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
end
