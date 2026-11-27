defmodule Bonfire.Federate.ActivityPub.OutgoingMentionLinksTest do
  @moduledoc """
  Mention links in the `content` of outgoing objects, as Mastodon reads them. Mastodon makes a preview card from the first link it doesn't skip, and skips one when its `class` matches `u-url` or `h-card`, its `rel` has `tag`, or its `href` is the mentioned actor's `url`. Its web UI shows a link as a mention only when the `href` is that `url`.

  The remote actor here has a `url` (`/@karen`) that differs from its id (`/users/karen`), as Mastodon actors do.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @remote_actor "https://mocked.local/users/karen"
  @remote_actor_url "https://mocked.local/@karen"

  setup do
    Process.put(:federating, true)

    # `.local` is not a known TLD, and posts are processed with TLD validation unless this is set (read at runtime by `Bonfire.Tag.TextContent.Process`). Safe to set since this module is `async: false`.
    previous_skip = System.get_env("SKIP_LINK_DOMAINS_VALIDATION")
    System.put_env("SKIP_LINK_DOMAINS_VALIDATION", "1")

    on_exit(fn ->
      if previous_skip,
        do: System.put_env("SKIP_LINK_DOMAINS_VALIDATION", previous_skip),
        else: System.delete_env("SKIP_LINK_DOMAINS_VALIDATION")
    end)

    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: "https://mocked.local/.well-known/webfinger" <> _} ->
        json(Simulate.webfingered())

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _karen} = AdapterUtils.get_by_url_ap_id_or_username(@remote_actor)

    me = fake_user!()
    bob = fake_user!()

    {:ok, me: me, bob: bob}
  end

  # Milkdown inserts a mention as plain `@handle` text, which the server turns into a markdown link; the HTML stand-in gets an HTML anchor
  for editor <- [Bonfire.Editor.Milkdown, Bonfire.Federate.ActivityPub.Test.HTMLOutputEditor] do
    describe "with #{inspect(editor)}" do
      setup %{me: me} do
        me =
          Bonfire.Common.Settings.put([:ui, :rich_text_editor], unquote(editor), current_user: me)
          |> current_user()

        {:ok, me: me}
      end

      test "a remote mention links to the actor's url, marked as a mention", %{me: me, bob: bob} do
        content = outgoing_content(me, "hi @karen@mocked.local and @#{bob.character.username}")

        karen_link = link_with_text(content, "karen")
        assert Floki.attribute(karen_link, "href") == [@remote_actor_url]
        assert_mention_link(content, karen_link)
      end

      test "a local mention keeps its canonical URL, marked as a mention", %{me: me, bob: bob} do
        content = outgoing_content(me, "hi @karen@mocked.local and @#{bob.character.username}")

        bob_link = link_with_text(content, bob.character.username)
        assert Floki.attribute(bob_link, "href") == [Bonfire.Common.URIs.canonical_url(bob)]
        assert_mention_link(content, bob_link)
      end

      test "a body that starts with a hashtag still has its mentions as links", %{me: me} do
        content = outgoing_content(me, "#first see @karen@mocked.local")

        refute Floki.text(content) =~ "]("
        karen_link = link_with_text(content, "karen")
        assert Floki.attribute(karen_link, "href") == [@remote_actor_url]
        assert_mention_link(content, karen_link)
      end
    end
  end

  defp outgoing_content(me, body) do
    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: me,
               post_attrs: %{post_content: %{html_body: body}},
               boundary: "public"
             )

    assert {:ok, ap_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)
    Floki.parse_fragment!(ap_activity.object.data["content"])
  end

  defp link_with_text(content, text) do
    links = Floki.find(content, "a")

    Enum.find(links, &(Floki.text(&1) =~ text)) ||
      flunk("No link with #{inspect(text)} in: #{Floki.raw_html(content)}")
  end

  # Mastodon skips links whose class matches `u-url` or `h-card` when picking a preview card, and its microformats parsing expects `<span class="h-card"><a class="u-url mention">`
  defp assert_mention_link(content, link) do
    classes = link |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
    assert "u-url" in classes, "Expected u-url class in: #{Floki.raw_html(link)}"
    assert "mention" in classes, "Expected mention class in: #{Floki.raw_html(link)}"

    assert link in Floki.find(content, "span.h-card > a"),
           "Expected the link inside span.h-card in: #{Floki.raw_html(content)}"
  end
end
