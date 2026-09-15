if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.GroupActorDeclarationsTest do
    @moduledoc """
    What our own Group actor declares about who may join it.

    `openness` is Mobilizon's `mz:` term for who may JOIN, which is the membership dimension. It is read straight off the group's dimension slugs, so what we advertise cannot drift from what we enforce. (The AS2 `manuallyApprovesFollowers` boolean answers a different question, who may FOLLOW, and `Bonfire.Federate.ActivityPub.PersonActorDeclarationsTest` covers that one.)

    This is what a remote mirror is scaffolded from: `Categories.remote_dims/1` reads `openness` back and cascades it to a visibility, so a group that overstates its own restriction is mirrored as a community nobody there can join or follow.
    """
    use Bonfire.Federate.ActivityPub.DataCase, async: false

    alias Bonfire.Federate.ActivityPub.{Adapter, AdapterUtils}
    alias Bonfire.Classify.Categories
    alias Bonfire.Social.Graph.Follows

    import Bonfire.Classify.Simulate

    defp actor_data(group) do
      assert %{data: data} = AdapterUtils.format_actor(group, "Group")
      data
    end

    describe "the entry rule a group declares" do
      # The case every other test in the tree builds by default, and the one a dance pair federates: a group created without dimensions gets `membership: "on_request"` from `resolve_dims/1`, so that is what it has to say it is.
      test "a group created without dimensions declares the membership it was actually given" do
        group = fake_group!(fake_user!())

        assert actor_data(group)["openness"] == "moderated",
               "an unconfigured group reviews requests to join, so declaring `invite_only` shuts out people it would in fact admit"
      end

      test "each membership slug is declared as its fediverse equivalent" do
        for {membership, openness} <- [
              {"open", "open"},
              {"on_request", "moderated"},
              {"invite_only", "invite_only"}
            ] do
          group = fake_group!(fake_user!(), %{membership: membership})

          assert actor_data(group)["openness"] == openness,
                 "a #{membership} group must declare #{openness}"
        end
      end
    end

    # The round trip, in one process: what a local group declares is exactly what a peer scaffolds its mirror from, so a declaration that overstates the restriction is refused on the far side rather than here. This is the non-federated half of `Dance.GroupPostTest`, which follows a mirrored group from the other instance.
    describe "a mirror scaffolded from those declarations" do
      test "can be followed by a stranger when the origin group admits one" do
        group = fake_group!(fake_user!())
        declarations = Adapter.remote_declarations(actor_data(group))

        assert {:ok, mirror} =
                 Categories.create_remote(
                   %{
                     name: "Mirrored #{id(group)}",
                     username: "mirrored_#{System.unique_integer([:positive])}"
                   },
                   remote_declarations: declarations
                 )

        someone = fake_user!()

        assert {:ok, _} = Follows.follow(someone, mirror),
               "the origin group lets a stranger ask to join, so its mirror must not be more closed than the group it mirrors"
      end
    end
  end
end
