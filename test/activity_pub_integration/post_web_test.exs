defmodule Bonfire.Federate.ActivityPub.PostWebTest do
  use Bonfire.Federate.ActivityPub.ConnCase
  import Tesla.Mock
  import Untangle
  alias Bonfire.Posts
  use Bonfire.Common.Repo

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: "https://pixelfed.local/users/dajbelshaw"} ->
        json(Simulate.actor_json("https://pixelfed.local/users/dajbelshaw"))

      _ ->
        raise Tesla.Mock.Error, "Request not mocked"
    end)
    |> IO.inspect(label: "setup done")

    :ok
  end

  describe "can" do
    test "fetch local post from AP API with Pointer ID, and take into account unindexable setting" do
      user =
        fake_user!()
        |> IO.inspect(label: "a user")

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

    test "process pixelfed activity with image" do
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
