defmodule Bonfire.Federate.ActivityPub.RemoteGroupProfileUITest do
  @moduledoc """
  The profile page (`/@handle`) of a remote `Group` on an instance with no group pages: the social flavour, which has `bonfire_classify` but not `bonfire_ui_groups`. The group is mirrored as a `Category`, and with no `GroupLive` its page is `ProfileLive`. Its members write the posts and the group announces them, and the profile has to show those posts, as `/tag/<handle>` already does.

  Groups send their `Announce` in three shapes: with the post's id, with the post embedded, and with the author's `Create` of it embedded (FEP-1b12, as Lemmy does). Each is sent from a remote `Group` (the Flipboard magazine capture, hosts rewritten) and, as the control that the path works at all, from a remote `Person`. A third announcer is the same `Group` announcing a post whose own `audience` names it (how a Bonfire group relays its members' posts): that also publishes the post in the group, which is asserted first where the group is a `Category`.

  Also guards the case with no `bonfire_classify` at all, where the group falls back to being a remote user (`Users.create_remote/2`) and its `Announce`s are stored as its boosts.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Ecto.Query
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @public "https://www.w3.org/ns/activitystreams#Public"

  @group "https://flipboard.local/magazines/6_IpBYSbRV-7tt-Yfrp6tA:m:89340020"
  @person "https://mocked.local/users/karen"
  @member "https://mastodon.local/users/reporter"

  # `group_audience` is the same group, announcing a post whose own `audience` names it: the shape in which a Bonfire group relays its members' posts, which also publishes the post in the group
  @announcers [person: @person, group: @group, group_audience: @group]
  @announcer_labels %{
    person: "remote person's",
    group: "remote group's",
    group_audience: "remote group's (the post names it in `audience`)"
  }
  @shapes [
    id: "the post's id",
    object: "the post embedded",
    create: "the author's Create embedded"
  ]
  @setups [social: "in the social flavour", no_classify: "without classify"]

  setup do
    group_json =
      @fixtures |> Path.join("flipboard/magazine_actor.json") |> File.read!() |> Jason.decode!()

    # every member post a test announces, so the `Announce` that names only its id can be resolved
    posts =
      for {setup, _} <- @setups, {kind, _} <- @announcers, {shape, _} <- @shapes, into: %{} do
        note = member_note(setup, kind, shape)
        {note["id"], note}
      end

    served =
      Map.merge(posts, %{
        @group => group_json,
        @person => APSimulate.actor_json(@person),
        @member => APSimulate.actor_json(@member, "reporter")
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

    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account), me: me}
  end

  for {setup, setup_label} <- @setups,
      {kind, announcer} <- @announcers,
      {shape, shape_label} <- @shapes do
    @setup setup
    @kind kind
    @announcer announcer
    @shape shape

    test "#{setup_label}, a #{@announcer_labels[kind]} Announce with #{shape_label} shows on its profile",
         %{conn: conn, me: me} do
      with_flavour(@setup, fn ->
        assert {:ok, announcer} = Adapter.maybe_create_remote_actor(%{"id" => @announcer})
        assert_mirrored_as(@setup, @kind, announcer)

        announcer = repo().maybe_preload(announcer, :character)
        note = member_note(@setup, @kind, @shape)

        assert {:ok, _} = Transformer.handle_incoming(announce(@announcer, note, @shape))

        assert {:ok, %{pointer_id: post_id}} = ActivityPub.Object.get_cached(ap_id: note["id"]),
               "the announced post is stored"

        assert is_binary(post_id), "the announced post is linked to a local record"

        stored = activities_of(post_id, announcer)

        # positive first: the post is published IN the group, before anything is asserted about how it is listed
        if @setup == :social and @kind == :group_audience,
          do: assert_published_in_group(post_id, announcer, stored)

        assert Bonfire.Social.Boosts.boosted?(announcer, post_id),
               "the Announce is stored as the announcer's boost; the post's activities (subject, verb, feed) are: #{inspect(stored)}"

        # what `ProfileLive` loads for `/@handle` (`do_prepare_feed_assigns/4`)
        assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post_id,
                 by: id(announcer),
                 current_user: me
               ),
               "the post is in the announcer's :user_activities feed (`subjects: [:by]`); the post's activities (subject, verb, feed) are: #{inspect(stored)}"

        conn
        |> visit("/@#{announcer.character.username}")
        |> wait_async()
        |> assert_has_or_open_browser("article", text: post_text(@setup, @kind, @shape))
      end)
    end
  end

  # the social flavour has `bonfire_classify` and not `bonfire_ui_groups`
  defp with_flavour(:social, fun),
    do: Bonfire.Common.Testing.with_extension_disabled(:bonfire_ui_groups, fun)

  defp with_flavour(:no_classify, fun),
    do: Bonfire.Common.Testing.with_extension_disabled(:bonfire_classify, fun)

  # published in the group, not only boosted by it: the group is the post's tree parent, and the group's outbox lists it
  # separate assertions rather than one boolean, so a failure says which part is missing
  defp assert_published_in_group(post_id, group, stored) do
    assert {:ok, _, %{id: group_id}} = Bonfire.Classify.Categories.group_of_object(post_id)
    assert group_id == id(group), "its tree parent is the group"

    # a Flipboard magazine declares no moderators and no members, so it is mirrored as a `:topic` (`Categories.remote_type/1`), and only a `:group` has the moderators ACL attached to what is published in it (`Boundaries.acl_ids_for_published_in/1`), so no ACL is asserted here
    assert group.type == :topic

    assert Enum.any?(stored, fn {_subject, _verb, feed} -> feed == :announcer_outbox end),
           "the group's outbox lists it; the post's activities (subject, verb, feed) are: #{inspect(stored)}"
  end

  defp assert_mirrored_as(:social, kind, announcer) when kind in [:group, :group_audience] do
    assert %Bonfire.Classify.Category{} = announcer,
           "with classify, a remote Group is mirrored as a Category (got #{inspect(announcer.__struct__)})"
  end

  defp assert_mirrored_as(_setup, _kind, announcer) do
    assert %Bonfire.Data.Identity.User{} = announcer,
           "a remote Person, or any actor without classify, is a user (got #{inspect(announcer.__struct__)})"
  end

  # each activity on the post as {subject, verb, feed}, with the ids that matter here named
  defp activities_of(post_id, announcer) do
    # bound first: the `e` macro as a map key crashes the Erlang compiler
    announcer_id = id(announcer)
    outbox_id = e(announcer, :character, :outbox_id, nil)
    names = %{announcer_id => :announcer, outbox_id => :announcer_outbox}

    from(a in Bonfire.Data.Social.Activity,
      where: a.object_id == ^post_id,
      left_join: fp in Bonfire.Data.Social.FeedPublish,
      on: fp.id == a.id,
      select: {a.subject_id, a.verb_id, fp.feed_id}
    )
    |> repo().all()
    |> Enum.map(fn {subject, verb, feed} ->
      {Map.get(names, subject, subject), Bonfire.Boundaries.Verbs.get_slug(verb),
       Map.get(names, feed, feed)}
    end)
  end

  defp post_text(setup, kind, shape),
    do: "A member post announced by the #{kind} as #{shape} (#{setup})"

  defp member_note(setup, kind, shape) do
    note = %{
      "id" => "#{@member}/statuses/#{setup}-#{kind}-#{shape}",
      "type" => "Note",
      "attributedTo" => @member,
      "content" => "<p>#{post_text(setup, kind, shape)}</p>",
      "published" => "2026-11-01T10:00:00Z",
      "to" => [@public],
      "cc" => ["#{@member}/followers"]
    }

    if kind == :group_audience, do: Map.put(note, "audience", @group), else: note
  end

  defp announce(announcer, note, shape) do
    object =
      case shape do
        :id ->
          note["id"]

        :object ->
          note

        :create ->
          create = %{
            "id" => "#{note["id"]}/activity",
            "type" => "Create",
            "actor" => @member,
            "to" => note["to"],
            "cc" => note["cc"],
            "object" => note
          }

          # as Lemmy does, the activity names the group too when the post does
          if note["audience"], do: Map.put(create, "audience", note["audience"]), else: create
      end

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{note["id"]}/announces/#{shape}",
      "type" => "Announce",
      "actor" => announcer,
      "to" => [@public],
      "cc" => ["#{announcer}/followers"],
      "object" => object,
      "published" => "2026-11-01T11:00:00Z"
    }
  end
end
