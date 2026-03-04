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

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{
        method: :get,
        url: "https://mocked.local/.well-known/nodeinfo"
      } ->
        %Tesla.Env{status: 404, body: ""}
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
      discussion_url: Bonfire.Common.URIs.based_url("/discussion/" <> id(original_post)),
      post_url: Bonfire.Common.URIs.based_url("/post/" <> id(original_post)),
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
      |> debug("quote post create activity")

    # Use handle_incoming to trigger the transformer
    {:ok, activity} =
      ActivityPub.Federator.Transformer.handle_incoming(create_activity)
      |> debug("processed quote post activity")

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

    ## Check ActivityPub representation to verify quote handling

    # Fetch the ActivityPub JSON representation
    {:ok, %{data: ap_json}} =
      ActivityPub.Object.get_cached(pointer: quote_post)
      |> debug("ActivityPub object for local quote post")

    # Verify the quote field is present
    assert ap_json["quote"] == context.original_url

    # When user quotes their own post no authorization stamp is required, but we currently add one anyway
    assert ap_json["quoteAuthorization"]

    # Verify FEP-e232 Link tag compatibility
    link_tags =
      (ap_json["tag"] || [])
      |> Enum.filter(fn tag ->
        is_map(tag) and
          tag["type"] == "Link" and
          tag["rel"] == "https://misskey-hub.net/ns#_misskey_quote" and
          tag["href"] == context.original_url
      end)

    assert length(link_tags) > 0
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

  test "makes a request to quote a local post when boundaries don't directly allow quoting (but allow requesting)",
       context do
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
    assert Quotes.requested?(id(quote_post), context.original_post)
    assert {:ok, _request} = Quotes.requested(quote_post, context.original_post)

    # Verify the request appears in the quoted post creator's notifications
    assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, "This is my original content",
             current_user: context.user
           )

    # Bonfire.Boundaries.Debug.debug_object_acls(context.original_post)

    ## Check ActivityPub representation to verify quote is not included when not yet approved

    # Fetch the ActivityPub JSON representation
    {:ok, %{data: ap_json}} =
      ActivityPub.Object.get_cached(pointer: quote_post)
      |> debug("ActivityPub object for local quote post")

    # Verify the quote field is NOT present
    refute ap_json["quote"] == context.original_url

    # When user quotes their own post no authorization stamp is required, but we currently add one anyway
    refute ap_json["quoteAuthorization"]

    # Verify FEP-e232 Link tag compatibility
    link_tags =
      (ap_json["tag"] || [])
      |> Enum.filter(fn tag ->
        is_map(tag) and
          tag["type"] == "Link" and
          tag["rel"] == "https://misskey-hub.net/ns#_misskey_quote" and
          tag["href"] == context.original_url
      end)

    refute length(link_tags) > 0

    assert ap_json["interactionPolicy"]["canQuote"]["automaticApproval"]
  end

  test "accepting a quote request adds quoteAuthorization to the AP JSON", context do
    other_user = fake_user!()

    # other_user creates a quote of user's post (creates a request since no direct permission)
    quote_attrs = %{
      post_content: %{html_body: "Quoting this! #{context.original_url}"}
    }

    {:ok, quote_post} =
      Posts.publish(
        current_user: other_user,
        post_attrs: quote_attrs,
        boundary: "public"
      )

    # Verify request was created
    assert {:ok, _request} = Quotes.requested(quote_post, context.original_post)

    # Before acceptance: ap_quote_fields should not return quoteAuthorization
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: other_user.id)
    {pre_fields, _} = Quotes.ap_quote_fields(actor, quote_post)
    refute pre_fields["quoteAuthorization"]

    # Accept the quote request
    {:ok, _} = Quotes.accept_quote(quote_post, context.original_post)

    # After acceptance: ap_quote_fields should include quoteAuthorization
    # (for local users, the QuoteAuthorization is created on-demand by ap_quote_fields
    # since the quoted object is local; for federated case, it's stored from Accept's result)
    {post_fields, post_tags} = Quotes.ap_quote_fields(actor, quote_post)

    assert post_fields["quoteAuthorization"],
           "quoteAuthorization should be available after acceptance"

    assert post_fields["quote"] == context.original_url
    assert length(post_tags) > 0
  end

  test "rejecting a previously accepted quote removes quoteAuthorization from the AP JSON",
       context do
    other_user = fake_user!()

    # other_user creates a quote of user's post (creates a request since no direct permission)
    quote_attrs = %{
      post_content: %{html_body: "Quoting this! #{context.original_url}"}
    }

    {:ok, quote_post} =
      Posts.publish(
        current_user: other_user,
        post_attrs: quote_attrs,
        boundary: "public"
      )

    # Verify request was created
    assert {:ok, _request} = Quotes.requested(quote_post, context.original_post)

    # Accept the quote request
    {:ok, accepted_quote} = Quotes.accept_quote(quote_post, context.original_post)

    # Simulate what federation does: store quoteAuthorization on the AP object
    # (in local-only tests, the Accept doesn't go through federation so it's not stored automatically)
    {:ok, %{data: data} = ap_object} = ActivityPub.Object.get_cached(pointer: accepted_quote)
    fake_auth_url = context.original_url <> "_authorization_test123"

    {:ok, _} =
      ActivityPub.Object.do_update_existing(ap_object, %{
        data:
          data
          |> Map.put("quoteAuthorization", fake_auth_url)
          |> Map.put("quote", context.original_url)
      })

    # Verify quoteAuthorization is present
    {:ok, %{data: stored_ap_json}} = ActivityPub.Object.get_cached(pointer: accepted_quote)
    assert stored_ap_json["quoteAuthorization"] == fake_auth_url

    # Now reject the previously accepted quote
    {:ok, _} =
      Quotes.reject_quote(accepted_quote, context.original_post, current_user: context.user)

    # Verify quoteAuthorization is removed after rejection
    {:ok, %{data: rejected_ap_json}} = ActivityPub.Object.get_cached(pointer: quote_post)
    refute rejected_ap_json["quoteAuthorization"]
    refute rejected_ap_json["quote"]

    # Verify quote relationship is removed
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    assert quote_tags == []
  end

  test "ap_quote_fields uses stored fields even when quote tags are missing (cross-instance scenario)",
       context do
    # This simulates what happens in dance tests: the AP object has quote + quoteAuthorization
    # stored from an Accept's result, but list_tags_quote returns empty because the tags
    # are in a different repo context.
    user = fake_user!()

    # Create a plain post (NOT a quote — no quote tags)
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "A post"}},
        boundary: "public"
      )

    # Manually store quote + quoteAuthorization on the AP object
    # (simulating what store_quote_authorization_on_ap_object does after receiving Accept)
    fake_quote_url = context.original_url
    fake_auth_url = "https://remote.example/auth/xyz"

    {:ok, %{data: data} = ap_object} = ActivityPub.Object.get_cached(pointer: post)

    ActivityPub.Object.do_update_existing(ap_object, %{
      data:
        data
        |> Map.put("quote", fake_quote_url)
        |> Map.put("quoteAuthorization", fake_auth_url)
    })

    # ap_quote_fields should still return the stored fields even with no quote tags
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user.id)
    {quote_fields, _quote_tags} = Quotes.ap_quote_fields(actor, post)

    assert quote_fields["quote"] == fake_quote_url,
           "quote field should be preserved from stored AP object data"

    assert quote_fields["quoteAuthorization"] == fake_auth_url,
           "quoteAuthorization should be preserved from stored AP object data"
  end

  test "skips quote creation when user doesn't have permission to request", context do
    # Block the other user from the original post's creator
    other_user = fake_user!()

    # Define boundaries that don't allow the other user to request quotes
    {:ok, _} = Bonfire.Boundaries.Blocks.block(other_user, current_user: context.user)

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
    refute Quotes.requested?(quote_post, context.original_post)

    assert [] = quote_post.media

    ## Check ActivityPub representation to verify quote is not included 

    # Fetch the ActivityPub JSON representation
    {:ok, %{data: ap_json}} =
      ActivityPub.Object.get_cached(pointer: quote_post)
      |> debug("ActivityPub object for local quote post")

    # Verify the quote field is NOT present
    refute ap_json["quote"] == context.original_url

    # When user quotes their own post no authorization stamp is required, but we currently add one anyway
    refute ap_json["quoteAuthorization"]

    # Verify FEP-e232 Link tag compatibility
    link_tags =
      (ap_json["tag"] || [])
      |> Enum.filter(fn tag ->
        is_map(tag) and
          tag["type"] == "Link" and
          tag["rel"] == "https://misskey-hub.net/ns#_misskey_quote" and
          tag["href"] == context.original_url
      end)

    refute length(link_tags) > 0
  end
end
