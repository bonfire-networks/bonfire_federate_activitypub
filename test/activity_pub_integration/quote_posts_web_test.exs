defmodule Bonfire.Federate.ActivityPub.QuotePostsWebTest do
  @moduledoc """
  Tests that verify a full local-to-local quote authorization flow as seen by a remote instance when fetching the AP JSON via HTTP 
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  alias Bonfire.Posts
  alias Bonfire.Social.Quotes

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

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    user = fake_user!()

    attrs = %{post_content: %{html_body: "This is my original content"}}

    {:ok, original_post} =
      Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    original_url = Bonfire.Common.URIs.canonical_url(original_post)

    %{
      user: user,
      original_post: original_post,
      original_url: original_url
    }
  end

  test "quote authorization appears in fetched AP JSON after acceptance and disappears after rejection",
       context do
    other_user = fake_user!()

    # other_user quotes user's post (creates a request since no direct permission)
    {:ok, quote_post} =
      Posts.publish(
        current_user: other_user,
        post_attrs: %{post_content: %{html_body: "Quoting this! #{context.original_url}"}},
        boundary: "public"
      )

    # Before acceptance: fetched AP JSON should NOT have quoteAuthorization
    pre_obj =
      build_conn()
      |> get("/pub/objects/#{quote_post.id}")
      |> response(200)
      |> Jason.decode!()

    refute pre_obj["quoteAuthorization"]
    refute pre_obj["quote"] == context.original_url

    # Accept the quote request
    {:ok, accepted_quote} = Quotes.accept_quote(quote_post, context.original_post)

    # After acceptance: fetched AP JSON should include quoteAuthorization
    accepted_obj =
      build_conn()
      |> get("/pub/objects/#{accepted_quote.id}")
      |> response(200)
      |> Jason.decode!()

    assert accepted_obj["quoteAuthorization"],
           "quoteAuthorization should be present in fetched AP JSON after acceptance"

    assert accepted_obj["quote"] == context.original_url

    # Verify FEP-e232 Link tag
    link_tags =
      (accepted_obj["tag"] || [])
      |> Enum.filter(fn tag ->
        is_map(tag) and
          tag["type"] == "Link" and
          tag["rel"] == "https://misskey-hub.net/ns#_misskey_quote" and
          tag["href"] == context.original_url
      end)

    assert length(link_tags) > 0

    # Reject the previously accepted quote
    {:ok, _} =
      Quotes.reject_quote(accepted_quote, context.original_post, current_user: context.user)

    # After rejection: fetched AP JSON should NOT have quoteAuthorization
    rejected_obj =
      build_conn()
      |> get("/pub/objects/#{quote_post.id}")
      |> response(200)
      |> Jason.decode!()

    refute rejected_obj["quoteAuthorization"],
           "quoteAuthorization should be removed from fetched AP JSON after rejection"

    refute rejected_obj["quote"] == context.original_url

    # Verify FEP-e232 Link tag is also removed
    rejected_link_tags =
      (rejected_obj["tag"] || [])
      |> Enum.filter(fn tag ->
        is_map(tag) and
          tag["type"] == "Link" and
          tag["rel"] == "https://misskey-hub.net/ns#_misskey_quote" and
          tag["href"] == context.original_url
      end)

    assert rejected_link_tags == []
  end
end
