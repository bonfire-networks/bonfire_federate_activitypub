defmodule Bonfire.Federate.ActivityPub.ThreadiverseFlagUITest do
  @moduledoc """
  Reporting a post in a group on another instance. Its moderators see the report only if it is sent to the group, and the threadiverse accepts a report only from a person (Lemmy's `Report.actor` is an `ApubPerson`), so the flag form offers it as its own checkbox, which sends the report as the reporter and says so. A local group's moderators see reports on its moderation page already, so the form does not offer it there.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures

  @community "https://lemmy.local/c/technology"

  @technology %{
    name: "Lemmy",
    dir: "lemmy",
    id: @community,
    actor: "community_actor.json",
    announces: ["announce_create_page_text.json"]
  }

  @group_checkbox "input[name=forward_to_group]"

  setup do
    served = Map.new(served_for([@technology]))

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
    receive_announce(announce)
    post = announced_post!("Lemmy text post", announce["object"]["object"]["id"])

    {:ok, group} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @community})

    account = fake_account!()
    me = fake_user!(account)
    {:ok, post: post, group: group, me: me, conn: conn(user: me, account: account)}
  end

  test "a post in a group on another instance can be reported to that group's moderators, as the reporter",
       %{conn: conn, post: post, me: me} do
    conn
    # the post's own page: a group's page lists posts as discussion previews, which have no actions menu
    |> visit("/post/#{id(post)}")
    |> wait_async()
    |> assert_has("[data-object_id='#{id(post)}']")
    |> within("[data-object_id='#{id(post)}']", fn session ->
      click_button(session, "[data-role=open_modal]", "Flag this")
    end)
    # |> open_browser()
    |> assert_has(@group_checkbox)
    |> assert_has("label", text: "will see that you reported it")
    |> fill_in("Add a comment for the flag", with: "spam")
    # not exact: the label holds the hint too
    |> check("my name for the group's moderators", exact: false)
    |> click_button("button[data-role=submit_flag]", "Flag this")
    |> assert_has("[role=alert]", text: "flagged!")

    {:ok, %{ap_id: reporter}} = ActivityPub.Actor.get_cached(pointer: me)

    assert [%{data: %{"to" => to}}] =
             Bonfire.Common.Repo.all(ActivityPub.Object)
             |> Enum.filter(&(&1.data["type"] == "Flag" and &1.data["actor"] == reporter))

    assert List.wrap(to) == [@community]
  end

  # the control: the same form, for a post in a LOCAL group, whose moderators see reports here
  test "a post in a local group offers no such checkbox", %{conn: conn, me: me} do
    group = Bonfire.Classify.Simulate.fake_group!(me)
    # someone else's post, since nobody flags their own
    author = fake_user!()
    assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(author, group)
    post_by_other = Bonfire.Classify.Simulate.fake_post_in_group!(author, group, "<p>theirs</p>")

    conn
    |> visit("/post/#{id(post_by_other)}")
    |> wait_async()
    |> assert_has("[data-object_id='#{id(post_by_other)}']")
    |> within("[data-object_id='#{id(post_by_other)}']", fn session ->
      click_button(session, "[data-role=open_modal]", "Flag this")
    end)
    |> assert_has("textarea[name=comment]")
    |> refute_has(@group_checkbox)
  end
end
