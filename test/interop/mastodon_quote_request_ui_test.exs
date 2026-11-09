defmodule Bonfire.Federate.ActivityPub.MastodonQuoteRequestUITest do
  @moduledoc """
  A Mastodon user quotes one of our user's posts, which needs approval. Mastodon sends a QuoteRequest to our user's inbox and shows the quote as "Pending" until it gets an Accept it can match. Our user presses "Accept quote" on the notification, and the Accept is delivered to Mastodon.

  The QuoteRequest is a real capture (`fixtures/mastodon/quote_request.json`, from `live_federation/quote_accept_live_test.exs`), re-pointed at a post of ours. What the Accept must hold is what Mastodon's `ActivityPub::Activity::Accept#accept_quote!` checks before it marks the quote accepted.

  Signature verification is faked the way the fork's controller tests do it (assign `valid_signature: true` and a `keyId` header).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  alias ActivityPub.Tests.ObanHelpers
  alias Bonfire.Posts
  alias Bonfire.Social.Quotes

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @remote_actor "https://mastodon.local/users/mayel"
  @remote_inbox "https://mastodon.local/users/mayel/inbox"
  # the post the capture quoted, which the test swaps for a post of ours
  @captured_quoted_post "https://bonfire.local/pub/objects/01M707BB0DYKCZJDYSY5F71R1Y"

  setup do
    # the `result` is fetched unsigned, as this test checks what is served, not who may fetch it
    previous = Application.get_env(:activity_pub, :reject_unsigned)
    Application.put_env(:activity_pub, :reject_unsigned, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:activity_pub, :reject_unsigned),
        else: Application.put_env(:activity_pub, :reject_unsigned, previous)
    end)

    # the notifications hold more than the test page size of 2
    Process.put([:bonfire, :default_pagination_limit], 10)

    account = fake_account!()
    author = fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "Something worth quoting"}},
        boundary: "public"
      )

    {:ok, %{data: %{"id" => post_ap_id}}} = ActivityPub.Object.get_cached(pointer: post)
    author_actor = ActivityPub.Actor.get_cached!(pointer: author.id)

    # the captured QuoteRequest, re-pointed at the post of ours (its `object`, the Note's `quote`, `_misskey_quote`, `quoteUri` and the link in its content)
    quote_request =
      @fixtures
      |> Path.join("mastodon/quote_request.json")
      |> File.read!()
      |> String.replace(@captured_quoted_post, post_ap_id)
      |> Jason.decode!()

    note = quote_request["instrument"]
    note_id = note["id"]
    test_pid = self()

    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(person_actor(@remote_actor))

      %{method: :get, url: ^note_id} ->
        json(note)

      %{method: :post, url: url, body: body} ->
        send(test_pid, {:posted, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    # the faked signature names the actor's key, which maps to them only once the actor is known, as it is after a real signature check fetched it
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)

    {:ok,
     account: account,
     author: author,
     author_actor: author_actor,
     post: post,
     post_ap_id: post_ap_id,
     note_id: note_id,
     quote_request: quote_request}
  end

  test "accepting a Mastodon quote request from the notification delivers an Accept that Mastodon can match",
       context do
    %{author: author, author_actor: author_actor, quote_request: quote_request} = context

    conn = deliver("/pub/actors/#{author_actor.username}/inbox", quote_request)
    assert conn.status == 200
    ObanHelpers.drain()

    assert {:ok, %{pointer_id: quote_post_id}} =
             ActivityPub.Object.get_cached(ap_id: context.note_id)

    assert Quotes.requested?(quote_post_id, context.post),
           "control: the quote needs approval"

    conn(user: author, account: context.account)
    |> visit("/notifications")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=quote_request_footer]")
    |> click_button("[data-role=quote_request_footer] button", "Accept quote")

    # accepting keeps the request and marks it accepted (declining deletes it)
    assert {:ok, %{accepted_at: %DateTime{}}} = Quotes.requested(quote_post_id, context.post),
           "accepted from the notification but the request is still pending"

    ObanHelpers.drain()

    accepts =
      for {:posted, @remote_inbox, body} <- flush_posted(),
          %{"type" => "Accept"} = activity <- [Jason.decode!(body)],
          do: activity

    assert [accept] = accepts, "expected one Accept delivered to the quoting account's inbox"

    # what Mastodon's `accept_quote!` checks: the object is the QuoteRequest it sent (a map resolves to its `id`), the actor is the quoted account, and the `result` is on the actor's host
    object = accept["object"]
    assert if(is_map(object), do: object["id"], else: object) == quote_request["id"]
    assert accept["actor"] == author_actor.ap_id
    assert @remote_actor in List.wrap(accept["to"])
    assert is_binary(accept["result"])
    assert URI.parse(accept["result"]).host == URI.parse(author_actor.ap_id).host

    # Mastodon keeps the `result` as the quote's approval, which others fetch to check it
    fetched =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/activity+json")
      |> Phoenix.ConnTest.dispatch(
        Application.fetch_env!(:bonfire, :endpoint_module),
        :get,
        URI.parse(accept["result"]).path
      )

    assert fetched.status == 200
    authorization = Jason.decode!(fetched.resp_body)
    assert authorization["type"] == "QuoteAuthorization"
    assert authorization["interactingObject"] == context.note_id
    assert authorization["interactionTarget"] == context.post_ap_id
  end

  defp deliver(path, doc) do
    build_conn()
    |> assign(:valid_signature, true)
    |> put_req_header("signature", "keyId=\"#{@remote_actor}#main-key\"")
    |> put_req_header("content-type", "application/activity+json")
    |> post(path, doc)
  end

  defp flush_posted(acc \\ []) do
    receive do
      {:posted, _, _} = msg -> flush_posted([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # `Simulate.actor_json/1` only answers for a handful of fixed ids, so rebase one onto the actor the fixture names
  defp person_actor(ap_id) do
    Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => "Person",
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end
end
