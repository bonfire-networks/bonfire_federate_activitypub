defmodule Bonfire.Federate.ActivityPub.RelativeLinksTest do
  @moduledoc """
  A relative link in a post's content (eg. `hashtag/research`) is resolved by the browser against whatever page shows it, so it leads somewhere different on every instance. These check that links are resolved against the post's own page before content leaves or after it arrives: incoming against the object's `url` (else its `id`), outgoing against the post's web URL.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  alias Bonfire.Common.URIs

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @remote_actor <> "/followers"} ->
        json(%{})

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  defp receive_note(note) do
    note =
      Map.merge(
        %{
          "type" => "Note",
          "attributedTo" => @remote_actor,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "published" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        note
      )

    {:ok, data} =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "id" => note["id"] <> "/activity",
        "actor" => @remote_actor,
        "to" => note["to"],
        "object" => note
      })

    assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    repo().maybe_preload(post, :post_content).post_content.html_body
  end

  describe "incoming" do
    test "relative links resolve against the object's id when it has no url" do
      html =
        receive_note(%{
          "id" => @remote_instance <> "/objects/rel-1",
          "content" =>
            ~s(<p>On <a href="hashtag/research">#research</a>, see <a href="/about">about</a> and <a href="https://else.local/x">else</a></p>)
        })

      assert html =~ ~s(href="#{@remote_instance}/objects/hashtag/research")
      assert html =~ ~s(href="#{@remote_instance}/about")
      assert html =~ ~s(href="https://else.local/x")
      refute html =~ ~s(href="hashtag/research")
    end

    test "relative links resolve against the object's HTML url when it has one" do
      html =
        receive_note(%{
          "id" => @remote_instance <> "/objects/rel-2",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => "video/mp4",
              "href" => @remote_instance <> "/v/2.mp4"
            },
            %{
              "type" => "Link",
              "mediaType" => "text/html",
              "href" => @remote_instance <> "/@karen/2"
            }
          ],
          "content" => ~s(<p>On <a href="hashtag/research">#research</a> today</p>)
        })

      assert html =~ ~s(href="#{@remote_instance}/@karen/hashtag/research")
    end

    test "a root-relative hashtag link that matches a Hashtag tag still becomes our local hashtag link" do
      html =
        receive_note(%{
          "id" => @remote_instance <> "/objects/rel-3",
          "content" =>
            ~s(<p>Some text about things</p><p><a href="/hashtag/xodus">#xodus</a></p>),
          "tag" => [
            %{
              "type" => "Hashtag",
              "name" => "#xodus",
              "href" => @remote_instance <> "/hashtag/xodus"
            }
          ]
        })

      assert html =~ "#xodus"
      refute html =~ ~s(href="#{@remote_instance}/hashtag/xodus")
    end

    test "a hashtag anchor with a trailing slash and tracking params still matches its Hashtag tag" do
      html =
        receive_note(%{
          "id" => @remote_instance <> "/objects/rel-4",
          "content" =>
            ~s(<p>Some text about <a href="#{@remote_instance}/Hashtag/Xodus/?utm_source=feed">#Xodus</a> today</p>),
          "tag" => [
            %{
              "type" => "Hashtag",
              "name" => "#xodus",
              "href" => @remote_instance <> "/hashtag/xodus"
            }
          ]
        })

      assert html =~ "#Xodus"
      refute html =~ "utm_source"
    end
  end

  describe "outgoing" do
    test "relative links in content and source resolve against the post's web URL" do
      Process.put(:federating, true)
      user = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{
              html_body:
                "On [#research](hashtag/research) and [about](/about), a long enough body"
            }
          },
          boundary: "public"
        )

      assert post.post_content.html_body =~ "](hashtag/research)",
             "control: the relative link is stored as written"

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
      object = ap_activity.object.data
      post_page = URIs.base_url() <> "/post/"

      assert object["content"] =~ ~s(href="#{post_page}hashtag/research")
      assert object["content"] =~ ~s(href="#{URIs.base_url()}/about")
      refute object["content"] =~ ~s(href="hashtag/research")

      assert %{"content" => source} = object["source"]
      assert source =~ "[#research](#{post_page}hashtag/research)"
      assert source =~ "[about](#{URIs.base_url()}/about)"
    end
  end
end
