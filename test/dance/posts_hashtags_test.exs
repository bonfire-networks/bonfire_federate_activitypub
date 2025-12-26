defmodule Bonfire.Federate.ActivityPub.Dance.PostsHashtagsTest do
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
  test "can make a public post with hashtags, and fetch it",
       context do
    user = context[:local][:user]

    Logger.metadata(action: "create local post 1")
    attrs = %{post_content: %{html_body: "test content one with hashtags #elixir #bonfire"}}
    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post)
      |> info("canonical_url")

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: "fetch post 1 by canonical_url")

      assert {:ok, object} =
               AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
               |> repo().maybe_preload(:post_content)

      assert object.post_content.html_body =~ "test content one with hashtags"
    end)
  end
end
