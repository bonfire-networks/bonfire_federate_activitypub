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
    test "trailing hashtags on the bottom line stay links in html_body, and are hidden when rendered" do
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

      # The trailing hashtags are stored as ordinary links, with no HTML around them
      refute post.post_content.html_body =~ "invisible"
      assert post.post_content.html_body =~ "#privacy"
      assert post.post_content.html_body =~ "#gdpr"

      # and are hidden when the body is rendered
      rendered =
        post.post_content.html_body
        |> Bonfire.Common.Text.maybe_markdown_to_html(hide_trailing_hashtags: true)
        |> Floki.parse_fragment!()

      assert rendered |> Floki.find(".invisible a") |> Enum.map(&Floki.text/1) == [
               "#privacy",
               "#gdpr"
             ]

      refute rendered |> Floki.find(".invisible") |> Floki.text() =~ "data protection"

      # But the hashtags should still be associated via tags
      hashtag_names =
        post.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "privacy" in hashtag_names
      assert "gdpr" in hashtag_names
    end

    test "inline hashtags mixed with text on the last line are NOT treated as trailing" do
      user = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{
              html_body: "This is about #privacy and also #gdpr regulations"
            }
          },
          boundary: "public"
        )

      post = repo().maybe_preload(post, [:post_content, tags: [:named, :character]])

      # Hashtags should remain visible inline (not wrapped in invisible)
      refute post.post_content.html_body =~ "invisible"
      assert post.post_content.html_body =~ "#privacy"
      assert post.post_content.html_body =~ "#gdpr"
    end

    test "the outgoing object hides trailing hashtags in its content, and its markdown source holds no HTML" do
      Process.put(:federating, true)
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

      assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
      object = ap_activity.object.data

      # other servers read `content`: the hashtags are links marked as tags (so Mastodon doesn't fetch link previews for them), and the trailing line of them is hidden
      content = Floki.parse_fragment!(object["content"])
      assert Floki.text(content) =~ "data protection"

      assert content |> Floki.find(~s(a[rel="tag ugc"])) |> Enum.map(&Floki.text/1) == [
               "#privacy",
               "#gdpr"
             ]

      assert content |> Floki.find(".invisible a") |> Enum.map(&Floki.text/1) == [
               "#privacy",
               "#gdpr"
             ]

      refute content |> Floki.find(".invisible") |> Floki.text() =~ "data protection"

      # servers that read `source` (eg. Mbin) render it as markdown, which shows any HTML in it escaped
      assert %{"mediaType" => "text/markdown", "content" => source} = object["source"]
      assert source =~ "data protection"
      refute source =~ "<"
      assert source =~ ~r{\[#privacy\]\(https?://[^)]+/hashtag/privacy\)}
      assert source =~ ~r{\[#gdpr\]\(https?://[^)]+/hashtag/gdpr\)}
    end

    # not run: posts stored with their trailing hashtags in a `<span class="invisible">` get no special handling, so their `source` keeps the span as stored. This checked a special case that turned it into a paragraph of its own
    # test "a post stored with its trailing hashtags in an invisible span sends a markdown source without it" do
    #   Process.put(:federating, true)
    #   user = fake_user!()
    #
    #   {:ok, post} =
    #     Bonfire.Posts.publish(
    #       current_user: user,
    #       post_attrs: %{
    #         post_content: %{
    #           html_body: "This is a post about data protection.\n#privacy #gdpr"
    #         }
    #       },
    #       boundary: "public"
    #     )
    #
    #   # how posts were stored before trailing hashtags were hidden at render
    #   post_content =
    #     post.post_content
    #     |> Ecto.Changeset.change(
    #       html_body:
    #         ~s|This is a post about data protection.<span class="invisible"> [#privacy](/hashtag/privacy) [#gdpr](/hashtag/gdpr)</span>|
    #     )
    #     |> repo().update!()
    #
    #   post = %{post | post_content: post_content}
    #
    #   assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
    #   object = ap_activity.object.data
    #
    #   assert %{"content" => source} = object["source"]
    #   assert source =~ "data protection"
    #   refute source =~ "<"
    #   assert source =~ ~r{\[#privacy\]\(https?://[^)]+/hashtag/privacy\)}
    #   assert source =~ ~r{\[#gdpr\]\(https?://[^)]+/hashtag/gdpr\)}
    #
    #   # `content` still hides them through the stored span
    #   assert object["content"]
    #          |> Floki.parse_fragment!()
    #          |> Floki.find(".invisible a")
    #          |> Enum.map(&Floki.text/1) == ["#privacy", "#gdpr"]
    # end
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

      # The trailing hashtag paragraph should be marked invisible
      assert post.post_content.html_body =~ ~r/<p class="invisible">.*privacy.*<\/p>/s
      assert post.post_content.html_body =~ ~r/<p class="invisible">.*gdpr.*<\/p>/s

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
