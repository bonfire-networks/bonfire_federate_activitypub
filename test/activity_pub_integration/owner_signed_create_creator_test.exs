defmodule Bonfire.Federate.ActivityPub.OwnerSignedCreateCreatorTest do
  @moduledoc """
  A `Create` by one actor (the sender) of a note that another actor (the owner) signed with a proof of its own is accepted, since the owner vouched for the note itself. The post that comes of it is the owner's: the creator is the owner, and never the sender, who only passed it on. (Refusing it would also be right; crediting the sender is not.)

  The control is a `Create` by the sender of the sender's own note, which makes the sender its creator, so the setup and the way of finding the creator are known to work.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock
  import ActivityPub.Test.IntegrityProofHelpers

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Common.URIs

  @public "https://www.w3.org/ns/activitystreams#Public"
  @sender "https://sender.local/users/sam"
  @owner "https://owner.local/users/olga"

  setup do
    owner_key = new_key(:ed25519)

    actors = %{
      @sender => Simulate.actor_json(@sender, "sam"),
      @owner =>
        Simulate.actor_json(@owner, "olga")
        |> Map.put("assertionMethod", [multikey(@owner, owner_key)])
    }

    # the origin of the note serves nothing, so the post can only come from the delivery
    mock(fn
      %{method: :get, url: url} ->
        case actors[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          doc -> json(doc)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    for id <- [@sender, @owner], do: {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: id)

    %{owner_key: owner_key}
  end

  # a `Create` by the sender of a note attributed to `owner`, the note's id on the owner's origin
  defp create_of(owner) do
    n = System.unique_integer([:positive])

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://sender.local/activities/create/#{n}",
      "type" => "Create",
      "actor" => @sender,
      "to" => [@public],
      "object" => %{
        "id" => "#{owner}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => owner,
        "content" => "<p>a note by #{owner} #{n}</p>",
        "published" => "2026-08-25T19:05:56Z",
        "to" => [@public]
      }
    }
  end

  # delivered to our inbox over the sender's verified HTTP signature
  defp delivered(create),
    do:
      Transformer.handle_incoming(create,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: @sender
      )

  # the canonical address of who created the post made from the note, or nil when none was made
  defp creator_of(note_id) do
    with {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) <-
           ActivityPub.Object.get_cached(ap_id: note_id),
         {:ok, post} <- Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true) do
      post
      |> repo().maybe_preload(created: [creator: [character: [:peered]]])
      |> then(&URIs.canonical_url(e(&1, :created, :creator, nil)))
    else
      _ -> nil
    end
  end

  test "control: a Create by the sender of the sender's own note makes the sender its creator" do
    create = create_of(@sender)

    assert {:ok, _} = delivered(create)

    assert creator_of(create["object"]["id"]) == @sender
  end

  test "a Create of a note that its owner signed makes the owner its creator, not the sender", %{
    owner_key: owner_key
  } do
    create = create_of(@owner)
    create = Map.put(create, "object", sign(create["object"], owner_key))

    delivered(create)

    # a post that is not made at all is a refusal, which is acceptable too
    case creator_of(create["object"]["id"]) do
      nil ->
        :ok

      creator ->
        assert creator == @owner,
               "the sender #{@sender} was credited with #{@owner}'s note: #{creator}"
    end
  end
end
