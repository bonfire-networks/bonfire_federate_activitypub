defmodule Bonfire.Federate.ActivityPub.GroupRelayedReceivedDocumentTest do
  @moduledoc """
  A member of a REMOTE instance acts on a post in one of OUR groups, with an activity their server signed (FEP-8b32), and the group announces it to its followers (FEP-1b12). A follower elsewhere can rely on the activity inside only if the author's proof still verifies, so the group must pass on the document exactly as it reached us, not the copy we normalised and stored.

  The library keeps that document with the activity's row (`data_received`, when its proof holds) and sends it as the Announce's object (its own tests check the bytes); what this checks is the adapter's part: that the group announces it, through `AdapterUtils.announce_by_group/2`, with the document as it reached us held for it, and, for a post, that each shape the group sends carries the `Create` as it reached us. And that an activity the group refuses is not announced at all.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  use Repatch.ExUnit

  import Tesla.Mock
  import ActivityPub.Test.IntegrityProofHelpers

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Worker.ReceiverHelpers

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @author "https://lemmy.local/u/mayel"
  @stranger "https://lemmy.local/u/mallory"
  @post "https://lemmy.local/post/67072971"
  @group_placeholder "https://bonfire.local/pub/group/GROUP"
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    key = new_key(:ed25519)

    author =
      APSimulate.actor_json(@author, "mayel")
      |> Map.put("assertionMethod", [multikey(@author, key)])

    mock(fn
      %{method: :get, url: @author} -> json(author)
      %{method: :get, url: @stranger} -> json(APSimulate.actor_json(@stranger, "mallory"))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    incoming =
      Path.join([@fixtures, "lemmy", "create_page_to_group.json"])
      |> File.read!()
      |> String.replace(@group_placeholder, actor.ap_id)
      |> Jason.decode!()

    # the post, in the group
    assert {:ok, _} = Transformer.handle_incoming(incoming)

    # what is published
    test_pid = self()

    Repatch.patch(ActivityPub.Federator, :publish, [mode: :shared], fn activity, opts ->
      send(test_pid, {:published, activity})
      Repatch.real(ActivityPub.Federator.publish(activity, opts))
    end)

    %{key: key, group_ap_id: actor.ap_id, incoming: incoming}
  end

  # delivered to our inbox, as the receiver hands it on after an HTTP signature by `signer`
  defp delivered(document, signer) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => document,
          "signed_by" => signer,
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :verified
    )
  end

  # a new post by the member to the group, signed by its author
  defp signed_create(%{key: key, incoming: incoming}) do
    n = System.unique_integer([:positive])

    incoming
    |> Map.put("id", "https://lemmy.local/activities/create/#{n}")
    |> put_in(["object", "id"], "#{@post}#{n}")
    |> sign(key, verification_method: @author <> "#ed25519-key")
  end

  # the group announced something
  defp announced do
    assert_received {:published, %{data: %{"type" => "Announce"}} = announce}
    announce
  end

  # the activity's row holds it as it reached us, which is what the library sends as the Announce's object
  defp held_as_received?(document) do
    {:ok, %ActivityPub.Object{data_received: received}} =
      ActivityPub.Object.get_cached(ap_id: document["id"])

    received == document
  end

  defp signed_update(%{key: key, group_ap_id: group_ap_id, incoming: incoming}, actor \\ @author) do
    %{
      "@context" => @context,
      "id" => "#{@post}/update/#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => actor,
      "to" => incoming["to"],
      "cc" => incoming["cc"],
      "audience" => group_ap_id,
      "object" => Map.put(incoming["object"], "content", "<p>an edit by its author</p>")
    }
    |> sign(key, verification_method: @author <> "#ed25519-key")
  end

  defp signed_like(%{key: key, group_ap_id: group_ap_id}) do
    %{
      "@context" => @context,
      "id" => "#{@post}/like/#{System.unique_integer([:positive])}",
      "type" => "Like",
      "actor" => @author,
      "to" => [group_ap_id],
      "audience" => group_ap_id,
      "object" => @post
    }
    |> sign(key)
  end

  # the post's origin answers 404 for it (the setup's catch-all), which confirms the deletion
  defp signed_delete(%{key: key, group_ap_id: group_ap_id, incoming: incoming}, actor \\ @author) do
    %{
      "@context" => @context,
      "id" => "#{@post}/delete/#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => actor,
      "to" => incoming["to"],
      "cc" => incoming["cc"],
      "audience" => group_ap_id,
      "object" => @post
    }
    |> sign(key, verification_method: @author <> "#ed25519-key")
  end

  test "the group announces a member's signed post with the Create as it reached us, in each shape it sends",
       context do
    create = signed_create(context)
    assert {:ok, _} = delivered(create, @author)
    announce = announced()

    # a follower elsewhere, so there is an inbox to prepare for
    {:ok, group} = ActivityPub.Actor.get_cached(ap_id: context.group_ap_id)
    announce = %{announce | data: Map.update(announce.data, "cc", [@stranger], &[@stranger | &1])}

    creates =
      for %{json: json} <-
            ActivityPub.Federator.APPublisher.prepare_publish_params(group, announce),
          %{"object" => %{"type" => "Create"} = inner} <- [Jason.decode!(json)],
          do: inner

    assert creates != [], "no shape carried the Create"

    for inner <- creates,
        do:
          assert(
            inner == create,
            "the Create goes out as we normalised it, which its proof does not cover"
          )
  end

  test "the group announces a member's signed edit with the document as it reached us", context do
    update = signed_update(context)
    assert {:ok, _} = delivered(update, @author)

    announced()

    assert held_as_received?(update),
           "the group's Announce goes out without the author's document, so its followers get our normalised copy, which the author's proof does not cover"
  end

  test "the group announces a member's signed like with the document as it reached us", context do
    like = signed_like(context)
    assert {:ok, _} = delivered(like, @author)

    announced()
    assert held_as_received?(like)
  end

  test "the group does not announce an edit of the post by someone else", context do
    update = signed_update(context, @stranger)
    delivered(update, @stranger)

    refute_received {:published, %{data: %{"type" => "Announce"}}},
                    "the group passed on an edit it refused"
  end

  test "the group announces a member's signed delete with the document as it reached us",
       context do
    delete = signed_delete(context)
    assert {:ok, _} = delivered(delete, @author)

    # the received document is used only when it is the stored activity, so it must keep the author's id
    assert {:ok, %{data: %{"type" => "Delete"}}} =
             ActivityPub.Object.get_cached(ap_id: delete["id"])

    announced()

    assert held_as_received?(delete),
           "the group's Announce goes out without the author's document, so its followers get our normalised copy, which the author's proof does not cover"
  end

  test "the group does not announce a delete of the post by someone else", context do
    delete = signed_delete(context, @stranger)
    delivered(delete, @stranger)

    refute_received {:published, %{data: %{"type" => "Announce"}}},
                    "the group passed on a delete it refused"
  end
end
