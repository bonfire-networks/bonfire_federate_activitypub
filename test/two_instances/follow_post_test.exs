defmodule Bonfire.Federate.ActivityPub.TwoInstances.FollowPostTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  alias Bonfire.Common.TestInstanceRepo

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows
  alias Bonfire.Federate.ActivityPub.Utils, as: IntegrationUtils

  @tag :test_instance
  test "outgoing follow makes requests" do
    local_follower = fake_user!("A Follower #{Pointers.ULID.generate()}")
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)
    info(follower_ap_id, "follower_ap_id")

    {remote_followed, followed_ap_id} =
      TestInstanceRepo.apply(fn ->
        repo().delete_all(ActivityPub.Object)
        remote_followed = fake_user!("B Followed #{Pointers.ULID.generate()}")
        {remote_followed, Bonfire.Me.Characters.character_url(remote_followed)}
      end)

    info(followed_ap_id, "followed_ap_id")

    assert {:ok, local_followed} = IntegrationUtils.get_or_fetch_and_create_by_uri(followed_ap_id)
    info(local_followed.character.username, "local_followed remote username")

    refute ulid(remote_followed) == ulid(local_followed)

    assert {:ok, request} = Follows.follow(local_follower, local_followed)
    info(request)

    # assert {:ok, _follow_activity} =
    #          Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{
    #            args: %{"op" => "create", "context_id" => request.id}
    #          })

    assert Bonfire.Social.Follows.requested?(local_follower, local_followed)
    refute Bonfire.Social.Follows.following?(local_follower, local_followed)

    followed =
      TestInstanceRepo.apply(fn ->
        info(follower_ap_id, "follower_ap_id")

        assert {:ok, remote_follower} =
                 IntegrationUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

        info(remote_follower.character.username, "remote_follower username")
        # dump(ActivityPub.Object.all())
        {:ok, _} = Bonfire.Me.Users.by_username(remote_follower.character.username)
        refute Bonfire.Social.Follows.following?(remote_follower, remote_followed)
        assert Bonfire.Social.Follows.requested?(remote_follower, remote_followed)
      end)
  end

  @tag :skip
  test "fetch post from AP API with Pointer ID" do
    user = fake_user!()
    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert {:ok, ap_activity} =
             Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{
               args: %{"op" => "create", "context_id" => post.id}
             })

    obj =
      build_conn()
      |> get("/pub/objects/#{post.id}")
      |> response(200)
      # |> debug
      |> Jason.decode!()

    assert obj["content"] =~ attrs.post_content.html_body
  end

  @tag :skip
  test "fetch post from AP API with AP ID" do
    user = fake_user!()
    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    # |> debug
    assert {:ok, ap_activity} =
             Bonfire.Federate.ActivityPub.APPublishWorker.perform(%{
               args: %{"op" => "create", "context_id" => post.id}
             })

    id = ap_activity.object.data["id"]

    obj =
      build_conn()
      |> get(id)
      |> response(200)
      |> Jason.decode!()

    assert obj["content"] =~ attrs.post_content.html_body
  end

  @tag :skip
  test "fetch post from AP API with friendly URL and Accept header" do
    user = fake_user!()
    attrs = %{post_content: %{html_body: "content"}}

    {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    assert build_conn()
           |> put_req_header("accept", "application/activity+json")
           |> get("/post/#{post.id}")
           |> redirected_to() =~ "/pub/objects/#{post.id}"
  end
end
