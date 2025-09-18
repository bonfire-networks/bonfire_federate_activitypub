defmodule Bonfire.Federate.ActivityPub.Dance.QuotePostsTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.PostContents
  alias Bonfire.Social.Quotes

  # Helper function to verify quote relationship exists
  defp quotes_post(quote_post, original_post) do
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)
    quote_tags != [] && List.first(quote_tags).id == original_post.id && quote_tags
  end

  describe "bidirectional quote post federation" do
    setup context do
      local_user = context[:local][:user]

      # remote_ap_id = context[:remote][:canonical_url]

      # {:ok, remote_user_on_local} =
      #   Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(remote_ap_id)

      # Create original post locally
      Logger.metadata(action: "create original post locally")
      original_attrs = %{post_content: %{html_body: "This is the original post content"}}

      {:ok, original_post} =
        Posts.publish(
          current_user: local_user,
          post_attrs: original_attrs,
          boundary: "public"
        )

      original_url =
        Bonfire.Common.URIs.canonical_url(original_post)
        |> info("original_post_url")

      %{original_post: original_post, original_url: original_url}
    end

    @tag :test_instance
    test "self-quote works and federates", context do
      debug(context, "Starting quote posts federation dance tests")
      local_user = context[:local][:user]
      remote_ap_id = context[:remote][:canonical_url]
      original_url = context[:original_url]
      original_post = context[:original_post]

      # --------------------------------------------------------------------
      # Test 1: Local quote post federating to remote
      Logger.metadata(action: "create local quote post")

      local_quote_attrs = %{
        post_content: %{html_body: "Local user quoting local post #{original_url}"}
      }

      {:ok, local_quote_post} =
        Posts.publish(current_user: local_user, post_attrs: local_quote_attrs, boundary: "public")
        |> repo().maybe_preload([:post_content, :tags, :media])

      assert local_quote_post.media == []
      assert quotes_post(local_quote_post, original_post)

      local_quote_url = Bonfire.Common.URIs.canonical_url(local_quote_post)

      {:ok, %{data: ap_json}} = ActivityPub.Object.get_cached(ap_id: local_quote_url)

      # assert ap_json["quote"] == original_url

      # Verify quoteAuthorization is present (self-quotes don't need to have authorization, but we include it anyway for now)
      assert ap_json["quoteAuthorization"]

      # Verify local quote federates to remote
      TestInstanceRepo.apply(fn ->
        Logger.metadata(action: "verify local quote post on remote instance")

        assert {:ok, remote_local_quote} =
                 AdapterUtils.get_by_url_ap_id_or_username(local_quote_url)
                 |> repo().maybe_preload([:post_content, :tags, :media])

        assert {:ok, remote_original} =
                 AdapterUtils.get_by_url_ap_id_or_username(original_url)

        assert remote_local_quote.post_content.html_body =~ "Local user quoting local post"
        assert remote_local_quote.media == []
        assert quotes_post(remote_local_quote, remote_original)

        # Verify AP JSON compliance

        {:ok, %{data: ap_json}} =
          ActivityPub.Object.get_cached(ap_id: local_quote_url)
          |> debug("Fetched AP JSON for local quote on remote instance")

        # Verify quoteAuthorization is present (self-quotes don't need to have authorization, but we include it anyway for now)
        assert ap_json["quoteAuthorization"]

        # Verify FEP-e232 Link tag compatibility
        link_tags =
          ap_json["tag"]
          |> Enum.filter(
            &(&1["type"] == "Link" and &1["rel"] == "https://misskey-hub.net/ns#_misskey_quote" and
                &1["href"] == original_url)
          )

        assert length(link_tags) > 0
      end)
    end

    @tag :test_instance
    test "Remote post requesting to quote local post, which needs to manually accept the request, and later manually rejects it instead",
         context do
      local_user = context[:local][:user]
      remote_ap_id = context[:remote][:canonical_url]
      original_url = context[:original_url]
      original_post = context[:original_post]

      # --------------------------------------------------------------------
      # Test 2: Remote post requesting to quote local post, which needs to manually accept the request 

      {remote_quote_post, remote_quote_url} =
        TestInstanceRepo.apply(fn ->
          remote_user = context[:remote][:user]

          Logger.metadata(action: "create remote quote post")

          remote_quote_attrs = %{
            post_content: %{html_body: "Remote user quoting the same post #{original_url}"}
          }

          {:ok, remote_quote_post} =
            Posts.publish(
              current_user: remote_user,
              post_attrs: remote_quote_attrs,
              boundary: "public"
            )

          assert {:ok, remote_original} =
                   AdapterUtils.get_by_url_ap_id_or_username(original_url)

          refute quotes_post(remote_quote_post, remote_original)

          {remote_quote_post, Bonfire.Common.URIs.canonical_url(remote_quote_post)}
        end)

      # Verify remote quote federates to local
      Logger.metadata(action: "verify remote quote post on local instance")

      assert {:ok, local_remote_quote} =
               AdapterUtils.get_by_url_ap_id_or_username(remote_quote_url)
               |> repo().maybe_preload([:post_content, :tags, :media])

      assert local_remote_quote.post_content.html_body =~ "Remote user quoting the same post"
      refute quotes_post(local_remote_quote, original_post)

      assert {:ok, local_remote_quote} =
               Quotes.accept_quote(local_remote_quote, original_post, current_user: local_user)
               |> debug("Accepted quote request")

      assert quotes_post(local_remote_quote, original_post)

      # check again with a fresh read
      {:ok, local_remote_quote} =
        Posts.read(local_remote_quote.id,
          current_user: local_user
        )

      assert quotes_post(local_remote_quote, original_post)

      # Verify QuoteAuthorization stamp in AP representation
      {:ok, %{data: local_quote_ap_json}} =
        ActivityPub.Object.get_cached(pointer: local_remote_quote)

      # assert local_quote_ap_json["quote"] == original_url
      assert local_quote_ap_json["quoteAuthorization"]

      TestInstanceRepo.apply(fn ->
        # Verify quote relationship is confirmed on remote side as well

        assert {:ok, remote_original} =
                 AdapterUtils.get_by_url_ap_id_or_username(original_url)

        assert quotes_post(remote_quote_post, remote_original)

        {:ok, %{data: remote_ap_json}} = ActivityPub.Object.get_cached(ap_id: remote_quote_url)

        # check that the quoteAuthorization field is removed
        assert remote_ap_json["quoteAuthorization"]
      end)

      # --------------------------------------------------------------------
      # Test 2b: send a Reject on the QuoteRequest after having accepted it to revert it
      Logger.metadata(action: "reject previously accepted quote")

      assert {:ok, _rejected_request} =
               Quotes.reject_quote(local_remote_quote, original_post, current_user: local_user)
               |> debug("Rejected quote request")

      {:ok, reverted_quote} = Posts.read(local_remote_quote.id, current_user: local_user)
      refute quotes_post(reverted_quote, original_post)

      # Verify QuoteAuthorization is removed from AP representation
      {:ok, %{data: reverted_ap_json}} = ActivityPub.Object.get_cached(pointer: reverted_quote)

      # check that the quoteAuthorization field is removed
      refute reverted_ap_json["quoteAuthorization"]

      TestInstanceRepo.apply(fn ->
        # Verify quote relationship is removed on remote side as well

        assert {:ok, remote_original} =
                 AdapterUtils.get_by_url_ap_id_or_username(original_url)

        refute quotes_post(remote_quote_post, remote_original)

        {:ok, %{data: remote_reverted_ap_json}} =
          ActivityPub.Object.get_cached(ap_id: remote_quote_url)

        # refute remote_reverted_ap_json["quote"] == original_url
        refute remote_reverted_ap_json["quoteAuthorization"]
      end)
    end

    @tag :test_instance
    test "Remote post requesting to quote local post, and then immediately (manually) reject it, before changing their mind and accepting it, and then finally just deleting the authorization",
         context do
      local_user = context[:local][:user]
      remote_ap_id = context[:remote][:canonical_url]
      original_url = context[:original_url]
      original_post = context[:original_post]

      # --------------------------------------------------------------------
      # Test 3: Remote post requesting to quote local post, and then immediately (manually) Reject it
      {remote_quote_post, remote_rejected_quote_url} =
        TestInstanceRepo.apply(fn ->
          remote_user = context[:remote][:user]

          Logger.metadata(action: "create another remote quote post for rejection test")

          remote_quote_attrs = %{
            post_content: %{html_body: "Remote user making another quote #{original_url}"}
          }

          {:ok, remote_quote_post} =
            Posts.publish(
              current_user: remote_user,
              post_attrs: remote_quote_attrs,
              boundary: "public"
            )

          {remote_quote_post, Bonfire.Common.URIs.canonical_url(remote_quote_post)}
        end)

      Logger.metadata(action: "Verify remote quote federates to local")

      # Verify remote quote federates to local
      assert {:ok, local_rejected_quote} =
               AdapterUtils.get_by_url_ap_id_or_username(remote_rejected_quote_url)
               |> repo().maybe_preload([:post_content, :tags, :media])

      refute quotes_post(local_rejected_quote, original_post)

      Logger.metadata(action: "reject the quote request")

      # Immediately reject the quote request
      assert {:ok, _rejected_request} =
               Quotes.reject_quote(local_rejected_quote, original_post, current_user: local_user)
               |> debug("Rejected quote request immediately")

      Logger.metadata(action: "Verify quote relationship remains absent")
      # Verify quote relationship remains absent
      {:ok, still_rejected_quote} = Posts.read(local_rejected_quote.id, current_user: local_user)
      refute quotes_post(still_rejected_quote, original_post)

      # Test 3b: now re-authorize the quote, then delete the quoteAuthorization without federating the deletion just to test if when re-verifying the quote it gets deleted again

      assert {:ok, now_accepted_quote} =
               Quotes.accept_quote(still_rejected_quote, original_post, current_user: local_user)
               |> debug("Accepted quote request")

      assert quotes_post(now_accepted_quote, original_post)

      {:ok, %{data: ap_json}} =
        ActivityPub.Object.get_cached(pointer: now_accepted_quote)

      assert ap_json["quoteAuthorization"]

      {:ok, object} =
        ActivityPub.Object.get_cached(ap_id: ap_json["quoteAuthorization"])
        |> debug("auth object")

      ActivityPub.Object.hard_delete(object)
      |> debug("Hard deleted quoteAuthorization object")

      TestInstanceRepo.apply(fn ->
        assert {:ok, remote_original} =
                 AdapterUtils.get_by_url_ap_id_or_username(original_url)

        # still cached as authorized
        assert quotes_post(remote_quote_post, remote_original)

        # double check authorization
        assert {:not_authorized, _} =
                 Quotes.verify_quote_authorization(remote_quote_post, remote_original)

        {:ok, remote_quote_post} =
          Posts.read(remote_quote_post.id, current_user: local_user)
          |> repo().maybe_preload([:post_content, :tags, :media])

        refute quotes_post(remote_quote_post, remote_original)
      end)
    end

    @tag :test_instance
    test "remote cannot request to quote when boundaries disallow requesting", context do
      local_user = context[:local][:user]
      local_ap_id = context[:local][:canonical_url]
      remote_ap_id = context[:remote][:canonical_url]
      remote_user = context[:remote][:user]

      # Create a post with boundaries that allow only guests to critique, but explicitly disallow activity_pub
      attrs = %{
        post_content: %{html_body: "No quotes allowed for remote users"}
      }

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: local_user,
          post_attrs: attrs,
          boundary: "public",
          to_circles: [
            {:guest, :contribute},
            # {:activity_pub, :participate},
            {:activity_pub, :cannot_request}
          ]
        )

      post_url = Bonfire.Common.URIs.canonical_url(post)

      # Try to quote from remote
      remote_quote_url =
        TestInstanceRepo.apply(fn ->
          remote_quote_attrs = %{
            post_content: %{
              html_body: "Trying to quote a post with no quote permission #{post_url}"
            }
          }

          {:ok, remote_quote_post} =
            Bonfire.Posts.publish(
              current_user: remote_user,
              post_attrs: remote_quote_attrs,
              boundary: "public"
            )

          {:ok, %{data: ap_json} = ap_object} =
            ActivityPub.Object.get_cached(ap_id: post_url)
            |> repo().maybe_preload([:pointer])

          # Should have a valid interactionPolicy denying critique for activity_pub
          assert %{"canQuote" => %{"automaticApproval" => [author_id]}} =
                   ap_json["interactionPolicy"]

          assert author_id == local_ap_id

          assert %{"canQuote" => %{"manualApproval" => [author_id]}} =
                   ap_json["interactionPolicy"]

          assert author_id == local_ap_id

          post = e(ap_object, :pointer, nil) || ap_object.pointer_id

          # Should not have quote relationship
          refute quotes_post(remote_quote_post, post)

          # Should not have a quote request
          refute Bonfire.Social.Quotes.requested?(remote_quote_post, post)

          Bonfire.Common.URIs.canonical_url(remote_quote_post)
        end)

      # Back on local, should have federated the post, but not the quote relationship or request
      assert {:ok, local_remote_quote} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
                 remote_quote_url
               )
               |> repo().maybe_preload([:post_content, :tags, :media])

      # Should not have quote relationship
      refute quotes_post(local_remote_quote, post)

      # Should not have a quote request
      refute Bonfire.Social.Quotes.requested?(local_remote_quote, post)

      # Should not have quoteAuthorization in AP JSON
      {:ok, %{data: ap_json}} =
        ActivityPub.Object.get_cached(pointer: local_remote_quote)

      refute ap_json["quoteAuthorization"]

      # Should have an interactionPolicy too
      assert %{"canQuote" => %{"automaticApproval" => _}} = ap_json["interactionPolicy"]
    end
  end

  @tag :test_instance
  test " Remote post requesting to quote local post, which gets auto-accepted thanks to circles/boundaries, but later manually rejected/reversed by the user",
       context do
    local_user = context[:local][:user]
    remote_ap_id = context[:remote][:canonical_url]

    # --------------------------------------------------------------------
    # Test 4: Remote post requesting to quote local post, which gets auto-accepted thanks to circles/boundaries
    # First, update boundaries to auto-accept quotes from remote user
    Logger.metadata(action: "setup auto-accept boundaries")

    {:ok, remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(remote_ap_id)

    {:ok, trusted_circle} =
      Bonfire.Boundaries.Circles.create(local_user, %{named: %{name: "auto quote trusted"}})

    {:ok, _} =
      Bonfire.Boundaries.Circles.add_to_circles(remote_user_on_local.id, trusted_circle)

    # Create a new post specifically for auto-acceptance testing
    Logger.metadata(action: "create new post for auto-acceptance test")

    auto_accept_attrs = %{
      post_content: %{html_body: "This post allows quotes from trusted circle"}
    }

    {:ok, post_to_auto_accept} =
      Posts.publish(
        current_user: local_user,
        post_attrs: auto_accept_attrs,
        boundary: "public",
        to_circles: %{
          trusted_circle.id => "contribute",
          remote_user_on_local.id => "contribute"
        }
      )

    auto_accept_url = Bonfire.Common.URIs.canonical_url(post_to_auto_accept)

    # TODO: Configure boundaries to auto-accept quotes from trusted_circle
    # This would require implementing boundary rules for quote auto-acceptance

    remote_auto_quote_url =
      TestInstanceRepo.apply(fn ->
        remote_user = context[:remote][:user]

        Logger.metadata(action: "create remote quote post for auto-acceptance test")

        remote_quote_attrs = %{
          post_content: %{html_body: "Remote quote post to be auto-accepted #{auto_accept_url}"}
        }

        {:ok, remote_quote_post} =
          Posts.publish(
            current_user: remote_user,
            post_attrs: remote_quote_attrs,
            boundary: "public"
          )
          |> debug("Published remote quote post for auto-acceptance test")

        assert {:ok, remote_auto_accept} =
                 AdapterUtils.get_by_url_ap_id_or_username(auto_accept_url)
                 |> repo().maybe_preload([:post_content, :tags, :media])

        Logger.metadata(action: "Verify auto-acceptance was received and processed on remote")
        assert quotes_post(remote_quote_post, remote_auto_accept)

        # actually verify the authorization 
        assert {:ok, :authorization_verified} =
                 Quotes.verify_quote_authorization(remote_quote_post, remote_auto_accept)

        Bonfire.Common.URIs.canonical_url(remote_quote_post)
      end)

    # Verify auto-acceptance 
    Logger.metadata(action: "Verify that auto-acceptance federated exists on local")

    assert {:ok, auto_accepted_quote} =
             AdapterUtils.get_by_url_ap_id_or_username(remote_auto_quote_url)
             |> repo().maybe_preload([:post_content, :tags, :media])

    {:ok, post_to_auto_accept} =
      Posts.read(post_to_auto_accept.id, current_user: local_user)
      |> repo().maybe_preload([:post_content, :tags, :media])

    assert quotes_post(auto_accepted_quote, post_to_auto_accept)

    # Verify auto-accepted quote has QuoteAuthorization
    {:ok, %{data: auto_ap_json}} = ActivityPub.Object.get_cached(pointer: auto_accepted_quote)
    # assert auto_ap_json["quote"] == auto_accept_url
    assert auto_ap_json["quoteAuthorization"]

    # actually verify the authorization 
    assert {:ok, :authorization_verified} =
             Quotes.verify_quote_authorization(auto_accepted_quote, post_to_auto_accept)

    # --------------------------------------------------------------------
    # Test 4b: TODO send a *Delete* for the QuoteAuthorization stamp (as an alternative implementation to simply Reject'ing the QuoteRequest) on the quote request to revert the decision after having (auto)accepted it
    Logger.metadata(action: "delete auto-accepted quote authorization")

    # Reuse the auto-accepted quote from Test 4
    assert {:ok, _deleted_auth} =
             Quotes.reject_quote(auto_accepted_quote, post_to_auto_accept,
               current_user: local_user,
               verb: :delete
             )
             |> debug("Deleted quote authorization")

    # Verify quote relationship is removed
    {:ok, deleted_quote} = Posts.read(auto_accepted_quote.id, current_user: local_user)
    refute quotes_post(deleted_quote, post_to_auto_accept)

    {:ok, %{data: auto_ap_json}} = ActivityPub.Object.get_cached(pointer: auto_accepted_quote)
    # assert auto_ap_json["quote"] == auto_accept_url

    # we should not only delete the QuoteAuthorization object but also remove the quoteAuthorization field
    refute auto_ap_json["quoteAuthorization"]

    # verify the authorization is revoked locally
    assert {:not_authorized, _} =
             Quotes.verify_quote_authorization(auto_accepted_quote, post_to_auto_accept)

    # check that it's removed on remote side as well
    TestInstanceRepo.apply(fn ->
      assert {:ok, remote_auto_accept} =
               AdapterUtils.get_by_url_ap_id_or_username(auto_accept_url)
               |> repo().maybe_preload([:post_content, :tags, :media])

      assert {:not_authorized, _} = Quotes.verify_quote_authorization(auto_accepted_quote)
    end)
  end
end
