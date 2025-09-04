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

  @tag :test_instance
  test "bidirectional quote post federation with AP JSON compliance and updates", context do
    local_user = context[:local][:user]

    remote_ap_id = context[:remote][:canonical_url]

    {:ok, remote_user_on_local} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(remote_ap_id)

    # create a local circle with remote user in it
    # {:ok, circle} = Bonfire.Boundaries.Circles.create(local_user, %{named: %{name: "trusted friends"}})
    # {:ok, _} = Bonfire.Boundaries.Circles.add_to_circles(remote_user_on_local.id, circle)

    # Create original post locally
    Logger.metadata(action: "create original post locally")
    original_attrs = %{post_content: %{html_body: "This is the original post content"}}

    {:ok, original_post} =
      Posts.publish(
        current_user: local_user,
        post_attrs: original_attrs,
        boundary: "public",
        to_circles:
          %{
            # circle.id => "contribute",
            # remote_user_on_local.id => "contribute"
          }
      )

    original_url =
      Bonfire.Common.URIs.canonical_url(original_post)
      |> info("original_post_url")

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
      {:ok, %{status: 200, body: body}} =
        ActivityPub.Federator.HTTP.get(
          local_quote_url,
          [{"accept", "application/activity+json"}]
        )

      ap_json = Jason.decode!(body)
      assert ap_json["quote"] == original_url

      # Verify FEP-e232 Link tag compatibility
      link_tags =
        ap_json["tag"]
        |> Enum.filter(
          &(&1["type"] == "Link" and &1["rel"] == "https://misskey-hub.net/ns#_misskey_quote")
        )

      assert length(link_tags) > 0
    end)

    # Test 2: Remote post requesting to quote local post, which needs to manually accept the request 

    remote_quote_url =
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

        Bonfire.Common.URIs.canonical_url(remote_quote_post)
      end)

    # Verify remote quote federates to local
    Logger.metadata(action: "verify remote quote post on local instance")

    assert {:ok, local_remote_quote} =
             AdapterUtils.get_by_url_ap_id_or_username(remote_quote_url)
             |> repo().maybe_preload([:post_content, :tags, :media])

    assert local_remote_quote.post_content.html_body =~ "Remote user quoting the same post"
    refute quotes_post(local_remote_quote, original_post)

    assert {:ok, local_remote_quote} =
             Quotes.accept_quote_from(remote_user_on_local, original_post,
               current_user: local_user
             )
             |> flood("Accepted quote request")

    assert quotes_post(local_remote_quote, original_post)

    # check again with a fresh read
    {:ok, local_remote_quote} =
      Posts.read(local_remote_quote.id,
        current_user: local_user
      )

    assert quotes_post(local_remote_quote, original_post)

    # Test 2b: Delete the QuoteRequest after having accepted it to revert it
    # TODO

    # Test 3: Remote post requesting to quote local post, which gets (manually) rejected
    # TODO

    # Test 4: Remote post requesting to quote local post, which gets auto-accepted thanks to circles/boundaries
    # TODO

    # Test 4b: Reject the quote request after having (auto)accepted it to revert it
    # TODO
  end
end
