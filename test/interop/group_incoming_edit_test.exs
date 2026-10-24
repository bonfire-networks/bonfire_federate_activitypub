defmodule Bonfire.Federate.ActivityPub.GroupIncomingEditTest do
  @moduledoc """
  A remote group relays an edit: the author of a post it announced sends an `Update`, and the group announces that `Update` to its followers, as `Announce{Update}`. We follow the group, so that is how the edit reaches us.

  The edit must be applied when the author sent it, and must not be when someone else did, whoever relays it. The group's `Announce` says the group passed it on, not that its sender may edit the post.

  Built on the Lemmy captures (`announce_create_page_text.json`), the same way `threadiverse_interop_test.exs` receives a relayed `Create`.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures

  @community "https://lemmy.local/c/technology"
  @lemmy %{
    name: "Lemmy",
    dir: "lemmy",
    id: @community,
    actor: "community_actor.json",
    announces: ["announce_create_page_text.json"]
  }
  # someone on the same instance who did not write the post
  @stranger "https://lemmy.local/u/mallory"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    served = Map.new(served_for([@lemmy]) ++ [{@stranger, author_actor(@stranger)}])

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    announce = fixture("lemmy", "announce_create_page_text.json")
    create = announce["object"]
    page = create["object"]

    # the post as the group first announced it
    receive_announce(announce)
    original = html_body(page["id"])
    assert is_binary(original), "control: the announced post should be stored with a body"

    {:ok, page: page, author: create["actor"], original: original}
  end

  test "an edit by the post's author, relayed by the group, is applied", %{
    page: page,
    author: author,
    original: original
  } do
    assert {:ok, _} =
             relayed_update(page, author, "<p>The body, edited by its author</p>")
             |> ActivityPub.Federator.Transformer.handle_incoming()

    refute html_body(page["id"]) == original
    assert html_body(page["id"]) =~ "edited by its author"
  end

  test "an edit by someone other than the author, relayed by the group, is not applied", %{
    page: page,
    author: author,
    original: original
  } do
    # the group relays it all the same: this is what a hostile or confused sender gets out of a group that only passes things on
    ActivityPub.Federator.Transformer.handle_incoming(
      relayed_update(page, @stranger, "<p>Hijacked by a stranger</p>")
    )

    assert html_body(page["id"]) == original

    # control: the same relay does apply the author's own edit afterwards
    assert {:ok, _} =
             relayed_update(page, author, "<p>The body, edited by its author</p>")
             |> ActivityPub.Federator.Transformer.handle_incoming()

    assert html_body(page["id"]) =~ "edited by its author"
  end

  # the group's `Announce` of an `Update` that `actor` sent for the post `page`
  defp relayed_update(page, actor, new_body) do
    unique = System.unique_integer([:positive])

    update = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{page["id"]}/update/#{unique}",
      "type" => "Update",
      "actor" => actor,
      "to" => [@public, "#{@community}/followers"],
      "audience" => @community,
      "object" => Map.merge(page, %{"content" => new_body, "attributedTo" => actor})
    }

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{@community}/activities/announce/#{unique}",
      "type" => "Announce",
      "actor" => @community,
      "to" => [@public],
      "cc" => ["#{@community}/followers"],
      "object" => update
    }
  end

  defp html_body(object_id) do
    announced_post!("Lemmy", object_id).post_content.html_body
  end
end
