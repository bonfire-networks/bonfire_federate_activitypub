defmodule Bonfire.Federate.ActivityPub.PostIntegrationTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock
  import Untangle
  alias Bonfire.Social.Posts
  use Bonfire.Common.Repo

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    :ok
  end

  describe "" do
    test "fetch post from AP API with Pointer ID" do
      user = fake_user!()
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
    end

    test "fetch post from AP API with AP ID" do
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

    test "fetch post from AP API with friendly URL and Accept header" do
      user = fake_user!()
      attrs = %{post_content: %{html_body: "content"}}

      {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

      assert build_conn()
             |> put_req_header("accept", "application/activity+json")
             |> get("/post/#{post.id}")
             |> redirected_to() =~ "/pub/objects/#{post.id}"
    end

    test "pixelfed activity with image" do
      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert post.__struct__ == Bonfire.Data.Social.Post
      debug(post)
      assert is_binary(debug(e(post, :post_content, :html_body, nil)))

      assert %{
               media: [
                 %Bonfire.Files.Media{
                   path:
                     "https://pixelfed-prod.nyc3.cdn.digitaloceanspaces.com/public/m/_v2/411/7198ec0c0-99bc91/6CWmVqUJS5Rx/cXZwkROZAkUOQEidxDNxZYlezi5nRBBLy5f2YAm0.jpg"
                 }
               ]
             } = post

      # assert doc =
      #          render_stateful(Bonfire.UI.Social.ActivityLive, %{
      #            id: "activity",
      #            object: post
      #          })

      # assert doc
      #        |> debug

    end
  end
end
