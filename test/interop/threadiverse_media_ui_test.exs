defmodule Bonfire.Federate.ActivityPub.ThreadiverseMediaUITest do
  @moduledoc """
  How a Lemmy link or image post shows here. Both are stored as `Bonfire.Files.Media` rather than as titled posts (a link post is a title plus a URL), with the title, and an image post's body, kept in `metadata.json_ld` (`threadiverse_interop_test.exs` checks that). These check that what's kept is also shown, and that replies thread under it.
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
    announces: ["announce_create_page.json"]
  }

  @image_community %{
    name: "Lemmy (image posts)",
    dir: "lemmy",
    id: "https://lemmy2.local/c/pics",
    actor: "community_actor_pics.json",
    announces: ["announce_create_page_image.json"]
  }

  setup do
    reply_author = fixture("lemmy", "create_note_reply_in_group.json")["object"]["attributedTo"]

    served =
      Map.new(
        served_for([@link_community, @image_community]) ++
          [{reply_author, author_actor(reply_author)}]
      )

    mock(fn
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
