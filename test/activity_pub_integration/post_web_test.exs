defmodule Bonfire.Federate.ActivityPub.PostIntegrationTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock
  import Untangle
  alias Bonfire.Social.Posts

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    :ok
  end

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
