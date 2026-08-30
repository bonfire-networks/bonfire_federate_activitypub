defmodule Bonfire.Federate.ActivityPub.PostMentionNoUrlPreviewTest do
  @moduledoc """
  Incoming remote posts must not unfurl a mention or hashtag anchor as a link preview. The actor and hashtag are already known from the `tag` array, so unfurling the content anchor is a duplicate fetch, one of the viral-post-storm hot paths.

  These drive `prepare_remote_content` directly (via the public `ap_receive_attrs_prepare` + `maybe_prepare_contents`) and assert on the returned `urls`: the mention/hashtag URL must be absent, the genuine plain link present. That is the exact list handed to the URL-preview fetcher, so it's the right observable, no Media/quote/spy indirection.

  Three layers keep a URL out of that list, and each realistic anchor exercises one: `replace_links` rewrites an anchor whose href (or its `/users/`->`/@` alternate) matches a resolved mention/hashtag; `exclude_urls` drops URLs matching a mention/hashtag key or `canonical_uri`; and the CSS markup filter in `Text.extract_urls_from_html/2` drops anchors carrying `u-url`/`mention`/`hashtag`/`rel=tag` (the net for a numeric-id web-form mention, whose `/@user` form no string rule can derive from the AP id).
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias Bonfire.Social.PostContents

  @remote_instance "https://mocked.local"
  # a numeric-id instance actor (todon.nl style): AP id is /ap/users/<numeric>, web form is /@user
  @todoner_apid @remote_instance <> "/ap/users/116504000946206292"
  @todoner_web @remote_instance <> "/@todoner"
  # a standard Mastodon actor: AP id is /users/user, web form is /@user
  @karen_apid @remote_instance <> "/users/karen"
  @karen_web @remote_instance <> "/@karen"
  @hashtag_uri @remote_instance <> "/tags/bonfire"
  @plain_link @remote_instance <> "/blog/article"

  setup do
    Process.put(:federating, true)

    mock_global(fn %{method: :get, url: url} ->
      cond do
        url == @todoner_apid -> json(Simulate.actor_json(@todoner_apid, "todoner"))
        url == @karen_apid -> json(Simulate.actor_json(@karen_apid))
        String.ends_with?(url, "/followers") -> json(%{})
        true -> %Tesla.Env{status: 404, body: ""}
      end
    end)

    :ok
  end

  # prepare a remote Note (content anchor + a genuine plain link, with the given tag array) and return its extracted+filtered urls
  defp prepared_urls(content_anchor, tags, author_apid) do
    creator = fake_user!()
    content = ~s(#{content_anchor} shared <a href="#{@plain_link}">a link</a>)
    activity_data = %{"actor" => author_apid}

    post_data = %{
      "type" => "Note",
      "content" => content,
      "tag" => tags,
      "attributedTo" => author_apid
    }

    attrs = PostContents.ap_receive_attrs_prepare(creator, activity_data, post_data)

    PostContents.prepare_remote_content(attrs, creator, parse_remote_links: true)
    |> e(:urls, [])
  end

  test "a standard-instance web-form mention (/@user) is kept out of the unfurl list by exclude_urls/replace_links" do
    urls =
      prepared_urls(
        ~s(<a href="#{@karen_web}" class="u-url mention">@karen</a>),
        [%{"type" => "Mention", "href" => @karen_apid, "name" => "@karen@mocked.local"}],
        @karen_apid
      )

    assert @plain_link in urls
    refute @karen_web in urls
  end

  test "a class-less mention anchor at the AP-id /users/ form (a Bonfire instance federating a Mastodon mention) is kept out of the unfurl list by exclude_urls" do
    # the shape of the reported bug (campground.bonfire.cafe): a post federated from another Bonfire instance mentions a remote Mastodon actor, rendered as a class-less external link to the actor's `/users/...` AP id (rel="nofollow noopener", no `mention`/`u-url` class), so only the tag-based exclude can catch it
    urls =
      prepared_urls(
        ~s(<a rel="nofollow noopener" href="#{@karen_apid}">@karen@mocked.local</a>),
        [%{"type" => "Mention", "href" => @karen_apid, "name" => "@karen@mocked.local"}],
        @karen_apid
      )

    assert @plain_link in urls
    refute @karen_apid in urls
  end

  test "a numeric-id web-form mention (/@user) is kept out of the unfurl list by the markup filter" do
    urls =
      prepared_urls(
        ~s(<a href="#{@todoner_web}" class="u-url mention">@todoner</a>),
        [%{"type" => "Mention", "href" => @todoner_apid, "name" => "@todoner@mocked.local"}],
        @todoner_apid
      )

    assert @plain_link in urls
    refute @todoner_web in urls
  end

  test "a hashtag anchor is kept out of the unfurl list" do
    urls =
      prepared_urls(
        ~s(<a href="#{@hashtag_uri}" class="hashtag" rel="tag">#bonfire</a>),
        [%{"type" => "Hashtag", "href" => @hashtag_uri, "name" => "#bonfire"}],
        @todoner_apid
      )

    assert @plain_link in urls
    refute @hashtag_uri in urls
  end
end
