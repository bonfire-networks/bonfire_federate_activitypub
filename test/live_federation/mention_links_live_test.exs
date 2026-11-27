defmodule Bonfire.Federate.ActivityPub.LiveFederation.MentionLinksLiveTest do
  @moduledoc """
  Mention and hashtag links in our posts, as a person on a real Mastodon server sees them through its API.

  Mastodon makes a preview card from the first link in a post that it can't tell is a mention or hashtag, and its web UI shows a link as a mention only when the `href` is the mentioned account's `url`. Our two posts (written with Milkdown, which sends mentions as plain `@handle` text) start with a hashtag, then mention the account there and another of our users; one ends there, the other has a web link after. The first must get no card, the second a card for the web link, and in both every mention link must point at a mentioned account's `url`.

  It needs an account on the server and a bore tunnel, so the server can fetch our post and users back. Put the URL and an access token (scopes `read`, `write`, `follow`) in the git-ignored `.env`, and run it through the tunnel recipe:

      LIVE_TEST_MASTODON_URL=https://…
      LIVE_TEST_MASTODON_TOKEN=…

      just test-federation-live-DRAGONS extensions/bonfire_federate_activitypub/test/live_federation/mention_links_live_test.exs

  It is skipped when the two variables are not set. `LIVE_TEST_ACCEPT_WAIT` (seconds, default 600) is how long each step waits for the server, and `LIVE_TEST_CARD_GRACE` (seconds, default 30) how much longer it gives the server to make a card for the post with no link, once the other has one.

  ⚠️ It acts as a real person: our test user mentions the account in two posts; both are deleted when the test ends.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :live_federation
  # committed data: the tunnelled server fetching back runs outside the test process
  @moduletag db_sandbox: false
  @moduletag capture_log: false

  alias Bonfire.Federate.ActivityPub.Testing.Interop
  alias Bonfire.Federate.ActivityPub.Testing.MastodonApi

  # a page with OpenGraph data, so Mastodon makes a card for it
  @web_link "https://github.com/bonfire-networks/bonfire-app/issues/1754"

  setup do
    Process.put(:federating, true)
    :ok
  end

  @tag skip:
         MastodonApi.from_env("mastodon") == nil &&
           "set LIVE_TEST_MASTODON_URL and LIVE_TEST_MASTODON_TOKEN in .env"
  @tag timeout: :timer.minutes(25)
  test "mastodon: a post with no web link gets no preview card, one with a web link gets it for that link, and mention links point at the mentioned accounts" do
    api = MastodonApi.from_env("mastodon")
    wait = String.to_integer(System.get_env("LIVE_TEST_ACCEPT_WAIT") || "600")
    grace = String.to_integer(System.get_env("LIVE_TEST_CARD_GRACE") || "30")

    {:ok, account} = MastodonApi.verify_credentials(api) |> ok_or_flunk("reading the account")
    handle = "@#{account["acct"]}@#{URI.parse(api.base).host}"
    assert {:ok, _} = Interop.fetch(handle)

    me =
      Bonfire.Common.Settings.put([:ui, :rich_text_editor], Bonfire.Editor.Milkdown,
        current_user: fake_user!()
      )
      |> current_user()

    bob = fake_user!()
    hashtag = "mentionprobe#{unique()}"
    mentions = "##{hashtag} #{handle} and @#{bob.character.username}"

    # the post with no web link goes first, so by the time the second one has its card, Mastodon has had the time to crawl the first
    no_link_post = publish(me, "#{mentions}, no link here")
    link_post = publish(me, "#{mentions}, see #{@web_link}")

    try do
      # Mastodon fetches cards in the background after storing the status, so wait for one: a status with no card at all would pass a `nil` check without proving anything
      link_status =
        Interop.await(
          fn ->
            case status_on(api, ap_id(link_post)) do
              %{"card" => %{}} = status -> status
              _ -> nil
            end
          end,
          seconds: wait
        ) ||
          flunk(
            "#{ap_id(link_post)} never showed on mastodon with a preview card within #{wait}s"
          )

      assert link_status["card"]["url"] == @web_link,
             "the card is for #{inspect(link_status["card"]["url"])}, not the web link: #{link_status["content"]}"

      assert_mentions_and_hashtag(link_status, hashtag)

      # Mastodon's crawl jobs run in parallel, so give the first post's a little longer before reading it
      Process.sleep(:timer.seconds(grace))

      no_link_status =
        status_on(api, ap_id(no_link_post)) ||
          flunk("#{ap_id(no_link_post)} never showed on mastodon")

      assert no_link_status["card"] == nil,
             "mastodon made a card for #{inspect(no_link_status["card"]["url"])} on a post with no web link: #{no_link_status["content"]}"

      assert_mentions_and_hashtag(no_link_status, hashtag)
    after
      cleanup(Bonfire.Social.Objects.delete(link_post, current_user: me), "our post with a link")

      cleanup(
        Bonfire.Social.Objects.delete(no_link_post, current_user: me),
        "our post with no link"
      )
    end
  end

  defp publish(me, body) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: body}},
        boundary: "public"
      )

    post
  end

  defp ap_id(post) do
    outgoing = Interop.outgoing_json(post) || flunk("no outgoing JSON for the post")
    ActivityPub.Object.get_ap_id(outgoing["object"]) || outgoing["id"]
  end

  # the status as the server has it now, or nil
  defp status_on(api, ap_id) do
    with {:ok, %{"id" => id}} <- MastodonApi.resolve_status(api, ap_id),
         {:ok, status} <- MastodonApi.status(api, id) do
      status
    else
      _ -> nil
    end
  end

  defp assert_mentions_and_hashtag(status, hashtag) do
    mention_urls = Enum.map(status["mentions"], & &1["url"])
    assert length(mention_urls) == 2, "expected 2 mentions, got: #{inspect(status["mentions"])}"

    mention_links =
      status["content"]
      |> Floki.parse_fragment!()
      |> Floki.find("a")
      |> Enum.filter(&String.starts_with?(Floki.text(&1), "@"))

    assert length(mention_links) == 2, "expected 2 mention links in: #{status["content"]}"

    for link <- mention_links do
      assert hd(Floki.attribute(link, "href")) in mention_urls,
             "#{Floki.raw_html(link)} doesn't point at a mentioned account's url (#{inspect(mention_urls)}), so Mastodon shows it as a web link"
    end

    assert hashtag in Enum.map(status["tags"], & &1["name"])
  end

  defp cleanup({:ok, _}, what), do: IO.puts("cleanup: #{what} deleted")

  defp cleanup(other, what),
    do: IO.puts("cleanup FAILED: could not delete #{what}: #{inspect(other)}")

  defp ok_or_flunk({:ok, _} = ok, _what), do: ok
  defp ok_or_flunk(other, what), do: flunk("#{what} failed: #{inspect(other)}")

  defp unique, do: System.unique_integer([:positive])
end
