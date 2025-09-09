defmodule Bonfire.Federate.ActivityPub.QuotePostsTest do
  use Bonfire.Federate.ActivityPub.DataCase
  import Tesla.Mock
  alias Bonfire.Posts
  alias Bonfire.Social.Quotes
  use Mneme
  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)

    user = fake_user!()

    # Create original post locally first
    original_attrs = %{post_content: %{html_body: "This is my original content"}}

    {:ok, original_post} =
      Posts.publish(current_user: user, post_attrs: original_attrs, boundary: "public")

    original_url = Bonfire.Common.URIs.canonical_url(original_post)

    # Create remote actor
    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    to = [ActivityPub.Config.public_uri()]

    %{
      user: user,
      original_post: original_post,
      discussion_url: Bonfire.Common.URIs.base_url("/discussion/" <> id(original_post)),
      post_url: Bonfire.Common.URIs.base_url("/post/" <> id(original_post)),
      original_url: original_url,
      actor: actor,
      to: to
    }
  end

  defp create_quote_post(context, quote_object) do
    # Create a full incoming Create activity to trigger the transformer
    create_activity =
      %{
        "type" => "Create",
        "id" => @remote_instance <> "/activities/" <> Needle.UID.generate(),
        "actor" => context.actor.ap_id,
        "to" => context.to,
        "object" => quote_object,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> flood("quote post create activity")

    # Use handle_incoming to trigger the transformer
    {:ok, activity} =
      ActivityPub.Federator.Transformer.handle_incoming(create_activity)
      |> flood("processed quote post activity")

    {:ok, quote_post} =
      Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      |> repo().maybe_preload([:post_content, :tags, :media])

    quote_post
  end

  defp assert_valid_quote_post(quote_post, original_post) do
    # Verify no media attachments for quote links
    assert quote_post.media == []

    # Verify the quote post was created correctly
    assert quote_post.post_content.html_body =~ "Great post!"

    # Verify quote relationship via tags
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags != []
    quote_tag = List.first(quote_tags)
    assert quote_tag.id == original_post.id

    assert Bonfire.Social.FeedLoader.feed_contains?(:remote, quote_post)
  end

  describe "incoming quote posts with different formats" do
    test "FEP-044f primary quote field", context do
      quote_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "type" => "Note",
        "attributedTo" => context.actor.ap_id,
        "to" => context.to,
        "content" =>
          "Great post! <span class=\"quote-inline\"><br/>RE: <a href=\"#{context.original_url}\">#{context.original_url}</a></span>",
        "quote" => context.original_url,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      quote_post = create_quote_post(context, quote_object)
      assert_valid_quote_post(quote_post, context.original_post)
    end

    test "ActivityStreams quoteUrl", context do
      quote_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "type" => "Note",
        "attributedTo" => context.actor.ap_id,
        "to" => context.to,
        "content" =>
          "Great post! <span class=\"quote-inline\"><br/>RE: <a href=\"#{context.original_url}\">#{context.original_url}</a></span>",
        "quoteUrl" => context.original_url,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      quote_post = create_quote_post(context, quote_object)
      assert_valid_quote_post(quote_post, context.original_post)
    end

    test "Fedibird quoteUri", context do
      quote_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "type" => "Note",
        "attributedTo" => context.actor.ap_id,
        "to" => context.to,
        "content" =>
          "Great post! <span class=\"quote-inline\"><br/>RE: <a href=\"#{context.original_url}\">#{context.original_url}</a></span>",
        "quoteUri" => context.original_url,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      quote_post = create_quote_post(context, quote_object)
      assert_valid_quote_post(quote_post, context.original_post)
    end

    test "Misskey _misskey_quote", context do
      quote_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "type" => "Note",
        "attributedTo" => context.actor.ap_id,
        "to" => context.to,
        "content" =>
          "Great post! <span class=\"quote-inline\"><br/>RE: <a href=\"#{context.original_url}\">#{context.original_url}</a></span>",
        "_misskey_quote" => context.original_url,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      quote_post = create_quote_post(context, quote_object)
      assert_valid_quote_post(quote_post, context.original_post)
    end

    test "FEP-e232 Link tag with Misskey rel", context do
      quote_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "type" => "Note",
        "attributedTo" => context.actor.ap_id,
        "to" => context.to,
        "content" =>
          "Great post! <span class=\"quote-inline\"><br/>RE: <a href=\"#{context.original_url}\">#{context.original_url}</a></span>",
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "tag" => [
          %{
            "type" => "Link",
            "mediaType" =>
              "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
            "rel" => "https://misskey-hub.net/ns#_misskey_quote",
            "href" => context.original_url
          }
        ]
      }

      quote_post = create_quote_post(context, quote_object)
      assert_valid_quote_post(quote_post, context.original_post)
    end

    test "full compatibility format with multiple fields", context do
      quote_object = %{
        "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
        "type" => "Note",
        "attributedTo" => context.actor.ap_id,
        "to" => context.to,
        "content" =>
          "Great post! <span class=\"quote-inline\"><br/>RE: <a href=\"#{context.original_url}\">#{context.original_url}</a></span>",
        "quote" => context.original_url,
        "quoteUrl" => context.original_url,
        "quoteUri" => context.original_url,
        "_misskey_quote" => context.original_url,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "tag" => [
          %{
            "type" => "Link",
            "mediaType" =>
              "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
            "rel" => "https://misskey-hub.net/ns#_misskey_quote",
            "href" => context.original_url
          }
        ]
      }

      quote_post = create_quote_post(context, quote_object)
      assert_valid_quote_post(quote_post, context.original_post)
    end
  end

  test "handles quote posts with mixed quote and regular link tags", context do
    quote_object = %{
      "id" => @remote_instance <> "/pub/" <> Needle.UID.generate(),
      "type" => "Note",
      "attributedTo" => context.actor.ap_id,
      "to" => context.to,
      "content" => "Great post! Also check this out: https://example.com/regular-link",
      "quote" => context.original_url,
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "tag" => [
        # Quote link
        %{
          "type" => "Link",
          "mediaType" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
          "rel" => "https://misskey-hub.net/ns#_misskey_quote",
          "href" => context.original_url
        },
        # Regular link  
        %{
          "type" => "Link",
          "mediaType" => "text/html",
          "href" => "https://example.com/regular-link",
          "name" => "Example Link"
        }
      ]
    }

    quote_post = create_quote_post(context, quote_object)

    # Should have regular link in attachments/media (but not quote link)
    assert [_] = quote_post.media

    # Should have quote relationship
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert [_] = quote_tags
    assert List.first(quote_tags).id == context.original_post.id
  end

  test "directly creates valid local quote post when boundaries allow", context do
    # Create a local quote post
    quote_attrs = %{
      post_content: %{
        html_body: "Great post! #{context.original_url}"
      }
    }

    {:ok, quote_post} =
      Posts.publish(
        current_user: context.user,
        post_attrs: quote_attrs,
        boundary: "public"
      )
      |> repo().maybe_preload([:post_content, :tags, :media])

    # Verify the quote post was created correctly
    assert quote_post.post_content.html_body =~ "Great post!"

    assert [] = quote_post.media

    # Verify quote relationship via tags
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags != []
    quote_tag = List.first(quote_tags)
    assert quote_tag.id == context.original_post.id

    assert Bonfire.Social.FeedLoader.feed_contains?(:local, quote_post)
  end

  test "creates quote post with post URL format", context do
    # Create a local quote post using the post URL format
    quote_attrs = %{
      post_content: %{
        html_body: "Great post! #{context.post_url}"
      }
    }

    {:ok, quote_post} =
      Posts.publish(
        current_user: context.user,
        post_attrs: quote_attrs,
        boundary: "public"
      )
      |> repo().maybe_preload([:post_content, :tags, :media])

    # Verify the quote post was created correctly
    assert quote_post.post_content.html_body =~ "Great post!"
    assert [] = quote_post.media

    # Verify quote relationship via tags
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags != []
    quote_tag = List.first(quote_tags)
    assert quote_tag.id == context.original_post.id
  end

  test "creates quote post with discussion URL format", context do
    # Create a local quote post using the discussion URL format
    quote_attrs = %{
      post_content: %{
        html_body: "Great discussion! #{context.discussion_url}"
      }
    }

    {:ok, quote_post} =
      Posts.publish(
        current_user: context.user,
        post_attrs: quote_attrs,
        boundary: "public"
      )
      |> repo().maybe_preload([:post_content, :tags, :media])

    # Verify the quote post was created correctly
    assert quote_post.post_content.html_body =~ "Great discussion!"
    assert [] = quote_post.media

    # Verify quote relationship via tags
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags != []
    quote_tag = List.first(quote_tags)
    assert quote_tag.id == context.original_post.id
  end

  test "makes a request to quote a local post when boundaries don't directly allow quoting (but allow requesting)", context do
    # Create a local quote post
    quote_attrs = %{
      post_content: %{
        html_body: "Great post! #{context.original_url}"
      }
    }

    other_user = fake_user!()

    {:ok, quote_post} =
      Posts.publish(
        current_user: other_user,
        post_attrs: quote_attrs,
        boundary: "public"
      )
      |> repo().maybe_preload([:post_content, :tags, :media])

    # Verify the post was created correctly
    assert quote_post.post_content.html_body =~ "Great post!"

    assert [] = quote_post.media

    # Verify that quote is pending and has not been inserted via tags
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags == []

    # verify a Request was created to quote the original post
    assert  Quotes.requested?(other_user, id(quote_post), context.original_post)

    # Bonfire.Boundaries.Debug.debug_object_acls(context.original_post)
  end

  test "skips quote creation when user doesn't have permission to request", context do
    # Block the other user from the original post's creator
    other_user = fake_user!()
    
    # Create boundaries that don't allow the other user to request quotes
    {:ok, _} = Bonfire.Boundaries.Blocks.block(context.user, other_user)

    quote_attrs = %{
      post_content: %{
        html_body: "Great post! #{context.original_url}"
      }
    }

    {:ok, quote_post} =
      Posts.publish(
        current_user: other_user,
        post_attrs: quote_attrs,
        boundary: "public"
      )
      |> repo().maybe_preload([:post_content, :tags, :media])

    # Verify the post was created correctly but without quote relationship
    assert quote_post.post_content.html_body =~ "Great post!"
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags == []


    # Verify no request was created either
    refute Quotes.requested?(other_user, quote_post, context.original_post)


        assert [] = quote_post.media
  end
end
