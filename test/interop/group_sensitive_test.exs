defmodule Bonfire.Federate.ActivityPub.GroupSensitiveTest do
  @moduledoc """
  A remote Group that says it is `sensitive` (Lemmy and PieFed's NSFW community, Mbin's adult magazine) is mirrored marked sensitive here, on first sight and on every refetch or `Update`. Only its origin sets the mark: our admins and moderators cannot add or remove it on a mirror.

  Fixtures written from each peer's serializer, with `.local` hosts.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Classify.Categories

  @fixtures Path.join([__DIR__, "..", "fixtures"])

  @lemmy "https://lemmy.local/c/technology"
  @lemmy_nsfw "https://lemmy.local/c/nsfw_art"
  @piefed_nsfw "https://piefed.local/c/nsfw_photos"
  @mbin_adult "https://mbin.local/m/adult_comics"

  defp read(dir, name),
    do: @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp serve(actors) do
    mock(fn
      %{method: :get, url: url} ->
        case actors[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          actor -> json(actor)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)
  end

  defp mirror!(url) do
    assert {:ok, %Bonfire.Classify.Category{} = mirror} =
             Adapter.maybe_create_remote_actor(%{"id" => url})

    mirror
  end

  defp sensitive?(mirror) do
    {:ok, got} = Categories.get(id(mirror), [:default, skip_boundary_check: true])
    Categories.sensitive?(got)
  end

  # its origin's `Update`, which changes something besides (an unchanged actor document is not applied again)
  defp update_from_origin(served, url, changes) do
    updated =
      served[url]
      |> Map.merge(changes)
      |> Map.put("summary", "edited #{System.unique_integer([:positive])}")

    serve(Map.put(served, url, updated))

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "type" => "Update",
               "id" => "#{url}/activities/update/#{System.unique_integer([:positive])}",
               "actor" => url,
               "to" => ["https://www.w3.org/ns/activitystreams#Public"],
               "object" => updated
             })
  end

  setup do
    served = %{
      @lemmy => read("lemmy", "community_actor.json"),
      @lemmy_nsfw => read("lemmy", "community_actor_nsfw.json"),
      @piefed_nsfw => read("piefed", "community_actor_nsfw.json"),
      @mbin_adult => read("mbin", "magazine_actor_adult.json")
    }

    serve(served)

    {:ok, served: served}
  end

  test "a community that is not NSFW is mirrored unmarked" do
    assert sensitive?(mirror!(@lemmy)) == false
  end

  for {label, url} <- [
        {"a Lemmy NSFW community", @lemmy_nsfw},
        {"a PieFed NSFW community", @piefed_nsfw},
        {"an Mbin adult magazine", @mbin_adult}
      ] do
    test "#{label} is mirrored marked sensitive" do
      assert sensitive?(mirror!(unquote(url))) == true
    end
  end

  test "an Update that turns it off unmarks the mirror", %{served: served} do
    mirror = mirror!(@lemmy_nsfw)
    assert sensitive?(mirror) == true, "control: marked from the start"

    update_from_origin(served, @lemmy_nsfw, %{"sensitive" => false})

    assert sensitive?(mirror) == false
  end

  test "an Update that turns it on marks the mirror", %{served: served} do
    mirror = mirror!(@lemmy)
    assert sensitive?(mirror) == false, "control: unmarked from the start"

    update_from_origin(served, @lemmy, %{"sensitive" => true})

    assert sensitive?(mirror) == true
  end

  test "an Update with no `sensitive` at all unmarks the mirror", %{served: served} do
    mirror = mirror!(@lemmy_nsfw)
    assert sensitive?(mirror) == true, "control: marked from the start"

    served = Map.update!(served, @lemmy_nsfw, &Map.delete(&1, "sensitive"))
    update_from_origin(served, @lemmy_nsfw, %{})

    assert sensitive?(mirror) == false,
           "the origin stopped sending it, so the default applies, as for its other declarations"
  end

  test "a local admin cannot mark a mirror" do
    mirror = mirror!(@lemmy)
    admin = fake_admin!()

    refute match?({:ok, _}, Categories.update(admin, mirror, %{sensitive: true}))
    assert sensitive?(mirror) == false, "only the origin sets the mark on its group"
  end

  test "a local admin cannot unmark a mirror" do
    mirror = mirror!(@lemmy_nsfw)
    admin = fake_admin!()

    refute match?({:ok, _}, Categories.update(admin, mirror, %{sensitive: false}))
    assert sensitive?(mirror) == true, "only the origin sets the mark on its group"
  end
end
