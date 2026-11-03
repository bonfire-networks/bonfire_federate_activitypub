defmodule Bonfire.Federate.ActivityPub.LemmyFeaturedPinsTest do
  @moduledoc """
  A Lemmy moderator features a post with an `Add` to the community's `featured` collection, and unfeatures it with a `Remove`, cc'd to the community, which announces it (`send_add_featured_post` in Lemmy's `crates/apub/activities/src/community/collection_add.rs`). We pin the post into our mirror of the community, never onto the moderator, and only when the sender is the community or one of its moderators (`Categories.listed_moderator?/2`): sharing its host is not enough, since the pin is applied as the activity says.

  `add_featured_post.json` and `remove_featured_post.json` follow Lemmy's committed assets (`crates/apub/apub/assets/lemmy/activities/community/`), with hostnames, ids and the post rewritten to the community and post the other fixtures here use.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures
  alias Bonfire.Social.Pins

  @community "https://lemmy.local/c/technology"
  # read from this checkout rather than through `fixture/2`, whose path comes from wherever `ThreadiverseFixtures` was compiled
  @featured_fixtures Path.join([__DIR__, "..", "fixtures", "lemmy"])
  @stranger "https://elsewhere.local/u/stranger"
  @neighbour "https://lemmy.local/u/neighbour"

  @technology %{
    name: "Lemmy",
    dir: "lemmy",
    id: @community,
    actor: "community_actor.json",
    announces: ["announce_create_page_text.json"]
  }

  defp featured_fixture(name),
    do: @featured_fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  setup do
    served =
      Map.new(served_for([@technology]))
      |> Map.put(@stranger, author_actor(@stranger))
      |> Map.put(@neighbour, author_actor(@neighbour))
      # the lib dereferences an Add's `target`; Lemmy serves its community's `featured` as an OrderedCollection
      |> Map.put("#{@community}/featured", %{
        "type" => "OrderedCollection",
        "id" => "#{@community}/featured",
        "orderedItems" => []
      })

    mock_global(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    announce = fixture("lemmy", "announce_create_page_text.json")
    receive_announce(announce)
    post = announced_post!("Lemmy text post", announce["object"]["object"]["id"])

    {:ok, group} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @community})

    moderators = fixture("lemmy", "community_actor.json")["attributedTo"]
    assert {:ok, [_]} = Bonfire.Classify.Categories.sync_remote_moderators(group, moderators)

    {:ok, moderator} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
        featured_fixture("add_featured_post.json")["actor"]
      )

    %{group: group, post: post, moderator: moderator}
  end

  test "a moderator's Add to the community's featured pins the post into our mirror", %{
    group: group,
    post: post,
    moderator: moderator
  } do
    receive_announce(featured_fixture("add_featured_post.json"))

    assert Pins.pinned?(id(group), post)

    refute Pins.pinned?(id(moderator), post),
           "pinned onto the moderator rather than the community"
  end

  # a community relaying, or itself sending, a change to its own featured: the group branch, not the one for a sender's own profile
  test "an Add from the community itself to its featured pins the post into our mirror", %{
    group: group,
    post: post
  } do
    featured_fixture("add_featured_post.json")
    |> Map.merge(%{"actor" => @community, "id" => "#{@community}/activities/add/self"})
    |> receive_announce()

    assert Pins.pinned?(id(group), post)
  end

  test "the matching Remove unpins it", %{group: group, post: post} do
    receive_announce(featured_fixture("add_featured_post.json"))
    assert Pins.pinned?(id(group), post), "control: pinned"

    receive_announce(featured_fixture("remove_featured_post.json"))

    refute Pins.pinned?(id(group), post)
  end

  test "an Add from someone with no authority over the community is refused", %{
    group: group,
    post: post
  } do
    {:ok, stranger} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(@stranger)

    featured_fixture("add_featured_post.json")
    |> Map.merge(%{"actor" => @stranger, "id" => "#{@stranger}/activities/add/1"})
    |> receive_announce()

    refute Pins.pinned?(id(group), post)
    refute Pins.pinned?(id(stranger), post)
  end

  # sharing the community's host is not authority over it: any account there could otherwise feature into it
  test "an Add from an account on the community's own host that doesn't moderate it is refused",
       %{
         group: group,
         post: post
       } do
    {:ok, neighbour} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(@neighbour)

    featured_fixture("add_featured_post.json")
    |> Map.merge(%{"actor" => @neighbour, "id" => "#{@neighbour}/activities/add/1"})
    |> receive_announce()

    refute Pins.pinned?(id(group), post)
    refute Pins.pinned?(id(neighbour), post)
  end

  test "a Remove from an account on the community's own host that doesn't moderate it leaves the pin",
       %{group: group, post: post} do
    {:ok, _} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(@neighbour)

    receive_announce(featured_fixture("add_featured_post.json"))
    assert Pins.pinned?(id(group), post), "control: pinned"

    featured_fixture("remove_featured_post.json")
    |> Map.merge(%{"actor" => @neighbour, "id" => "#{@neighbour}/activities/remove/1"})
    |> receive_announce()

    assert Pins.pinned?(id(group), post)
  end
end
