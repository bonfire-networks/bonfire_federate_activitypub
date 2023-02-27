defmodule Bonfire.Federate.ActivityPub.Dance.FetchTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  @tag :test_instance
  test "can lookup from AP API with username, AP ID and with friendly URL",
       _context do
    # lookup 3 separate users to be sure

    remote = fake_remote!()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:username])

    assert object.profile.name == remote[:user].profile.name

    remote = fake_remote!()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

    assert object.profile.name == remote[:user].profile.name

    remote = fake_remote!()
    assert {:ok, object} = AdapterUtils.get_by_url_ap_id_or_username(remote[:friendly_url])

    assert object.profile.name == remote[:user].profile.name
  end

  @tag :test_instance
  test "can fetch public post from AP API with AP ID and with friendly URL and Accept header",
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

    post =
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
end
