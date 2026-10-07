defmodule Bonfire.Federate.ActivityPub.ThreadiverseMediaUITest do
  @moduledoc """
  How a Lemmy link or image post shows here. An image post, and a link post with no comment, are stored as `Bonfire.Files.Media`, with the title, and an image post's body, kept in `metadata.json_ld` (`threadiverse_interop_test.exs` checks that). A link post WITH a comment is a `Post`: its title, the comment as its body, and the link attached. These check that what's kept is also shown, and that replies thread under it.

  A link post's media is the LINK, not the thumbnail Lemmy sends beside it in `image`: a link shown as its thumbnail loses the link, which is what people posted.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures

  @link_community %{
    name: "Lemmy",
    dir: "lemmy",
    id: "https://lemmy.local/c/technology",
    actor: "community_actor.json",
    announces: ["announce_create_page.json", "announce_create_page_link_comment.json"]
  }

  @image_community %{
    name: "Lemmy (image posts)",
    dir: "lemmy",
    id: "https://lemmy2.local/c/pics",
    actor: "community_actor_pics.json",
    announces: ["announce_create_page_image.json"]
  }

  @unfurlable_article "https://thenewstack.io/everything-big-starts-small-building-open-social-web-apps/"
  @unfurled_image "https://thenewstack.local/og-cover.png"

  setup do
    reply_author = fixture("lemmy", "create_note_reply_in_group.json")["object"]["attributedTo"]

    served =
      Map.new(
        served_for([@link_community, @image_community]) ++
          [{reply_author, author_actor(reply_author)}]
      )

    mock(fn
      # the linked article of the post WITH a comment serves a preview image, so our unfurl finds one; the other post's article is a 404
      %{method: :get, url: @unfurlable_article} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html; charset=utf-8"}],
          body:
            ~s(<html><head><title>Building Open Social Web Apps</title><meta property="og:image" content="#{@unfurled_image}"></head><body></body></html>)
        }

      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    account = fake_account!()
    me = fake_user!(account)
    {:ok, conn: conn(user: me, account: account)}
  end

  defp group_of(community_id) do
    {:ok, group} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => community_id})

    group
  end

  test "a link post shows its title in the group's feed and on its own page", %{conn: conn} do
    announce = fixture("lemmy", "announce_create_page.json")
    title = announce["object"]["object"]["name"]
    receive_announce(announce)
    media = announced_post!("Lemmy link", announce["object"]["object"]["id"])

    group = group_of(@link_community.id)

    conn
    |> visit(Bonfire.Common.URIs.path(group))
    |> wait_async()
    |> assert_has_or_open_browser("article", text: title)

    conn
    |> visit(Bonfire.Common.URIs.path(media))
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=media_title]", text: title)
  end

  test "a link post without a comment shows its link, not its thumbnail", %{conn: conn} do
    announce = fixture("lemmy", "announce_create_page.json")
    object = announce["object"]["object"]
    [%{"href" => href}] = object["attachment"]
    receive_announce(announce)
    media = announced_post!("Lemmy link", object["id"])

    assert %Bonfire.Files.Media{} = media, "a link post with no comment is the link itself"

    assert media.path == href,
           "the media is the link, not the thumbnail in `image` (#{object["image"]["url"]})"

    conn
    |> visit(Bonfire.Common.URIs.path(media))
    |> wait_async()
    |> assert_has_or_open_browser("a[data-id=media_link][href='#{href}']")
  end

  test "a link post with a comment is a post with its title, the comment, and the link", %{
    conn: conn
  } do
    announce = fixture("lemmy", "announce_create_page_link_comment.json")
    object = announce["object"]["object"]
    [%{"href" => href}] = object["attachment"]
    receive_announce(announce)
    post = announced_post!("Lemmy link with comment", object["id"])

    assert %Bonfire.Data.Social.Post{} = post,
           "a comment is a body, which a post has and a media doesn't"

    assert post.post_content.name == object["name"]
    assert post.post_content.html_body =~ "Nice coverage"

    conn
    |> visit(Bonfire.Common.URIs.path(post))
    |> wait_async()
    |> assert_has_or_open_browser("*", text: "Nice coverage")
    |> assert_has("a[data-id=media_link][href='#{href}']")
  end

  # LazyImage puts the url in `src`, or in `data-src` while lazy-loading
  defp card_image(url),
    do: "[data-id=media_link] [src='#{url}'], [data-id=media_link] [data-src='#{url}']"

  test "a link card shows our unfurled image, else the thumbnail Lemmy sent", %{conn: conn} do
    with_comment = fixture("lemmy", "announce_create_page_link_comment.json")
    receive_announce(with_comment)
    post = announced_post!("Lemmy link with comment", with_comment["object"]["object"]["id"])

    conn
    |> visit(Bonfire.Common.URIs.path(post))
    |> wait_async()
    |> assert_has_or_open_browser(card_image(@unfurled_image))
    |> refute_has(card_image(with_comment["object"]["object"]["image"]["url"]))

    # control: this article serves no preview, so the card falls back to Lemmy's thumbnail
    without_comment = fixture("lemmy", "announce_create_page.json")
    receive_announce(without_comment)
    media = announced_post!("Lemmy link", without_comment["object"]["object"]["id"])

    conn
    |> visit(Bonfire.Common.URIs.path(media))
    |> wait_async()
    |> assert_has_or_open_browser(card_image(without_comment["object"]["object"]["image"]["url"]))
  end

  test "an image post shows its body, not only its title", %{conn: conn} do
    announce = fixture("lemmy", "announce_create_page_image.json")
    object = announce["object"]["object"]
    receive_announce(announce)
    media = announced_post!("Lemmy image", object["id"])

    conn
    |> visit(Bonfire.Common.URIs.path(media))
    |> wait_async()
    # the shown title and body, not just any text: the image's alt text and the modal caption carry them too
    |> assert_has_or_open_browser("[data-id=media_title]", text: object["name"])
    |> assert_has_or_open_browser("[data-id=media_description]", text: "cross-posted from")
  end

  test "a reply to a link post threads under it", %{conn: conn} do
    announce = fixture("lemmy", "announce_create_page.json")
    link_id = announce["object"]["object"]["id"]
    receive_announce(announce)
    media = announced_post!("Lemmy link", link_id)

    # the captured reply, pointed at the link post instead of its placeholder parent
    reply =
      fixture("lemmy", "create_note_reply_in_group.json")
      |> put_in(["object", "inReplyTo"], link_id)

    {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(reply)
    Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)

    reply_text =
      reply["object"]["content"]
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> String.trim()
      |> String.slice(0, 40)

    conn
    |> visit(Bonfire.Common.URIs.path(media))
    |> wait_async()
    |> assert_has_or_open_browser("*", text: reply_text)
  end
end
