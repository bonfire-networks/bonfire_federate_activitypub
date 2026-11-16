defmodule Bonfire.Federate.ActivityPub.MastodonClassesStorageTest do
  @moduledoc """
  A post from Mastodon is stored with the classes its markup carries for mentions, hashtags and shortened links (`u-url mention`, `mention hashtag`, `ellipsis`, as well as `invisible`), so that the styles for them apply to remote posts too. A class that no style of ours knows, such as a utility class a remote server could use to cover the page, is dropped, with the text it wraps kept.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  # as Mastodon writes a mention, a hashtag and a link it shortens, with a class of no meaning to us in the middle
  @content ~s|<p><span class="h-card" translate="no"><a href="https://mocked.local/@bob" class="u-url mention">@<span>bob</span></a></span> read <a href="https://example.com/a/long/path" target="_blank" rel="nofollow noopener"><span class="invisible">https://</span><span class="ellipsis">example.com/a/long</span><span class="invisible">/path</span></a> <span class="fixed inset-0">hostile</span> about <a href="https://mocked.local/tags/art" class="mention hashtag" rel="tag">#<span>art</span></a> today</p>|

  setup do
    author = "https://mocked.local/users/karen"

    Tesla.Mock.mock(fn
      %{method: :get, url: ^author} -> Tesla.Mock.json(Simulate.actor_json(author, "karen"))
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    data =
      "../fixtures/mastodon-post-activity-trailing-hashtags.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["object", "content"], @content)

    {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data, fetch_collection: false)

    assert {:ok, post} =
             Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
             |> repo().maybe_preload(:post_content)

    %{html: post.post_content.html_body}
  end

  test "control: the invisible parts of a shortened link keep their class, and a class of no meaning to us is dropped",
       %{html: html} do
    assert html =~ ~s|class="invisible"|
    assert html =~ "hostile", "the text of the dropped class is kept"
    refute html =~ "fixed inset-0"
    refute html =~ "fixed"
  end

  test "mentions, hashtags and shortened links keep their classes", %{html: html} do
    missing =
      for class <- ["u-url mention", "mention hashtag", "ellipsis"],
          not (html =~ ~s|class="#{class}"|),
          do: class

    assert missing == [], "stored without the classes #{inspect(missing)}: #{html}"
  end
end
