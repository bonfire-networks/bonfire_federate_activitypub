defmodule Bonfire.Federate.ActivityPub.EmbeddedObjectIdHostTest do
  @moduledoc """
  An object delivered inside someone's `Create` is taken as theirs only if its id is on their own host. A signed `Create` by actor A that carries an object whose id is on another host V's, and which names V's actor as its author, does not put that object under V's id: A can speak for A's host only.

  Each `Create` is posted to `/pub/shared_inbox` over a verified HTTP signature by A (faked the way the fork's controller tests do it: assign `valid_signature: true` and the signer), and the queued jobs are run. The control is A's own object, on A's host, which is stored the same way.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Data.Social.Created
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias ActivityPub.Tests.ObanHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"
  # the sender
  @sender "https://squatter.local/users/alice"
  # whose host the squatted id is on
  @victim "https://victim.local/users/vic"

  setup do
    mock(fn
      %{method: :get, url: @sender} -> json(Simulate.actor_json(@sender, "alice"))
      %{method: :get, url: @victim} -> json(Simulate.actor_json(@victim, "vic"))
      # nobody serves the objects
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
    end)

    # known, so a delivery signed by them is mapped to them
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @sender)
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @victim)

    :ok
  end

  # a `Create` by `@sender`, with `object_id` as its object's id, written by `author`
  defp create_doc(object_id, author) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://squatter.local/activities/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => @sender,
      "to" => [@public],
      "object" => %{
        "id" => object_id,
        "type" => "Note",
        "attributedTo" => author,
        "content" => "squatted #{System.unique_integer([:positive])}",
        "to" => [@public]
      }
    }
  end

  defp deliver_signed(signer_id, doc) do
    conn =
      build_conn()
      |> assign(:valid_signature, true)
      |> put_req_header("signature", "keyId=\"#{signer_id}#main-key\"")
      |> put_req_header("content-type", "application/activity+json")
      |> post("/pub/shared_inbox", doc)

    ObanHelpers.perform_all()
    conn
  end

  defp held?(id), do: match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: id))

  test "control: the sender's own object, on the sender's host, is stored" do
    object_id = "https://squatter.local/objects/#{System.unique_integer([:positive])}"

    deliver_signed(@sender, create_doc(object_id, @sender))

    assert held?(object_id)
  end

  test "an object on the victim's host that names the victim as its author is not stored under the victim's id" do
    object_id = "https://victim.local/objects/#{System.unique_integer([:positive])}"

    deliver_signed(@sender, create_doc(object_id, @victim))

    refute held?(object_id), "an object with the victim's id was stored from the sender's Create"
  end

  test "an object on the victim's host that names the sender as its author is not stored under the victim's id" do
    object_id = "https://victim.local/objects/#{System.unique_integer([:positive])}"

    deliver_signed(@sender, create_doc(object_id, @sender))

    refute held?(object_id),
           "an object with an id on the victim's host was stored from the sender's Create"
  end

  # whether a Bonfire object was made for this AP id
  defp linked?(id) do
    case Bonfire.Federate.ActivityPub.Peered.get_by_uri(id) do
      nil -> false
      {:error, _} -> false
      _peered -> true
    end
  end

  # the mocks of `setup/0`, plus the documents `docs` (a map of id => document) that their origins serve
  defp mock_serving(docs) do
    mock(fn
      %{method: :get, url: @sender} -> json(Simulate.actor_json(@sender, "alice"))
      %{method: :get, url: @victim} -> json(Simulate.actor_json(@victim, "vic"))
      %{method: :get, url: url} when is_map_key(docs, url) -> json(Map.fetch!(docs, url))
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
    end)
  end

  test "control: the sender's own object is stored and made into a Bonfire object" do
    object_id = "https://squatter.local/objects/#{System.unique_integer([:positive])}"

    deliver_signed(@sender, create_doc(object_id, @sender))

    assert held?(object_id)
    assert linked?(object_id)
  end

  test "the victim's origin serving the object: it is stored with the victim's data, and nothing is made from the sender's Create" do
    object_id = "https://victim.local/objects/#{System.unique_integer([:positive])}"

    mock_serving(%{
      object_id => %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => object_id,
        "type" => "Note",
        "attributedTo" => @victim,
        "content" => "the victim's own words",
        "to" => [@public]
      }
    })

    deliver_signed(@sender, create_doc(object_id, @victim))

    assert {:ok, %{data: data, pointer_id: post_id}} =
             ActivityPub.Object.get_cached(ap_id: object_id)

    assert data["content"] == "the victim's own words"
    assert data["attributedTo"] == @victim

    # the Bonfire object is the one made from the victim's own document, not from the sender's Create
    {:ok, victim} = AdapterUtils.get_character_by_ap_id(@victim)
    {:ok, sender} = AdapterUtils.get_character_by_ap_id(@sender)

    assert is_binary(post_id)
    assert %Created{creator_id: creator_id} = repo().get(Created, post_id)
    assert creator_id == id(victim)

    refute creator_id == id(sender),
           "the sender's Create made a Bonfire object for what the victim owns"
  end

  test "an object referenced by id, owned by the sender and served by its origin, is stored and made into a Bonfire object" do
    object_id = "https://squatter.local/objects/#{System.unique_integer([:positive])}"

    mock_serving(%{
      object_id => %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => object_id,
        "type" => "Note",
        "attributedTo" => @sender,
        "content" => "the sender's own words",
        "to" => [@public]
      }
    })

    doc = %{create_doc(object_id, @sender) | "object" => object_id}
    deliver_signed(@sender, doc)

    assert held?(object_id)
    assert linked?(object_id)
  end
end
