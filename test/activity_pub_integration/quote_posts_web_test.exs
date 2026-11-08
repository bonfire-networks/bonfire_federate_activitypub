defmodule Bonfire.Federate.ActivityPub.QuotePostsWebTest do
  @moduledoc """
  Tests that verify a full local-to-local quote authorization flow as seen by a remote instance when fetching the AP JSON via HTTP 
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  alias Bonfire.Posts
  alias Bonfire.Social.Quotes

  # these tests check what is served, not who may fetch it (that is `signed_fetch_public_actors_test.exs`), so they fetch unsigned, with signed fetches not required
  setup do
    previous = Application.get_env(:activity_pub, :reject_unsigned)
    Application.put_env(:activity_pub, :reject_unsigned, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:activity_pub, :reject_unsigned),
        else: Application.put_env(:activity_pub, :reject_unsigned, previous)
    end)
  end

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

    # deliberate lazy caller: a freshly-published post hasn't preloaded :peered
    original_url = Bonfire.Common.URIs.canonical_url(original_post, preload_if_needed: true)

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

  # A remote user's quote of our user's post needs approval: the author sees "wants to quote your post" in their notifications and presses Decline
  test "the author declining a remote quote request from their notifications shows no error" do
    account = fake_account!()
    author = fake_user!(account)

    {:ok, original_post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "This is my original content"}},
        boundary: "public"
      )

    original_url = Bonfire.Common.URIs.canonical_url(original_post, preload_if_needed: true)

    # the inbox holds more than the test page size of 2
    Process.put([:bonfire, :default_pagination_limit], 10)

    n = System.unique_integer([:positive])
    note_id = "#{@remote_actor}/statuses/#{n}"

    note = %{
      "id" => note_id,
      "type" => "Note",
      "attributedTo" => @remote_actor,
      "content" => "<p>Quoting this!</p><p>RE: #{original_url}</p>",
      "quote" => original_url,
      "to" => [ActivityPub.Config.public_uri()],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    mock(fn
      %{method: :get, url: @remote_actor} -> json(Simulate.actor_json(@remote_actor))
      %{method: :get, url: ^note_id} -> json(note)
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "id" => "#{note_id}/quote_request",
               "type" => "QuoteRequest",
               "actor" => @remote_actor,
               "object" => original_url,
               "instrument" => note
             })

    assert {:ok, %{pointer_id: quote_post_id}} = ActivityPub.Object.get_cached(ap_id: note_id)

    assert Quotes.requested?(quote_post_id, original_post),
           "control: the quote needs approval"

    conn(user: author, account: account)
    |> visit("/notifications")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=quote_request_footer]")
    |> click_button("[data-role=quote_request_footer] button", "Decline")
    |> wait_async()
    |> refute_has("[data-id=flash_error]")

    refute Quotes.requested?(quote_post_id, original_post),
           "declined from the notification but the request is still pending"
  end
end
