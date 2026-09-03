defmodule Bonfire.Federate.ActivityPub.GroupOutgoingInteropTest do
  @moduledoc """
  What a post published in one of OUR groups looks like on the wire.

  FEP-1b12 marks belonging with `audience` naming the group, and Lemmy additionally requires the group in `to`/`cc`: it reads addressing from those alone, so a post that names the group only in `audience` is delivered but not filed. Both are needed, and both have to appear on the OBJECT as well as the activity: Friendica's captures put `audience` only on the `Create`, which is why our own attribution code learned to check both, and Lemmy puts it on the `Page` too.

  This is the incoming work from the other side. Everything we ingest depends on remote implementations doing this; a Bonfire group that does not is invisible as a group, however well we read theirs.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Outgoing

  defp public_group(creator) do
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    group
  end

  defp group_ap_id(group) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)
    actor.ap_id
  end

  test "a post published in a group names the group in audience, to/cc, and on the object" do
    creator = fake_user!()
    group = public_group(creator)

    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>a post for the group</p>"}},
               boundary: "public",
               publish_in: uid(group)
             )

    activity = Outgoing.ap_activity!(post)
    data = activity.data
    group_ap_id = group_ap_id(group)

    assert group_ap_id in List.wrap(data["audience"]),
           "FEP-1b12 marks belonging with `audience`, so a group post without it is just a post"

    assert group_ap_id in (List.wrap(data["to"]) ++ List.wrap(data["cc"])),
           "Lemmy reads addressing from `to`/`cc` alone, so the group has to be there as well"

    # the stored object, which is what we SERVE and what a remote fetch returns — not whatever the
    # activity happens to carry inline
    assert {:ok, %{data: object_data}} = ActivityPub.Object.get_cached(pointer: post)

    assert group_ap_id in List.wrap(object_data["audience"]),
           "and on the object too: code that only checks the activity misses Friendica, code that only checks the object misses us"
  end
end
