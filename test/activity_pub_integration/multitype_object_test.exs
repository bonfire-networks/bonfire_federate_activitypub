defmodule Bonfire.Federate.ActivityPub.MultitypeObjectTest do
  @moduledoc """
  Objects that declare several AS2 types, e.g. a cuisine.social recipe as `["Note", "Preparation"]`.

  Finding a module for ANY of an object's types is treated as handling the whole object, so the types we don't know are discarded: a recipe becomes a plain `Post` whose body is a link-back stub, while the ingredients, steps and serving survive only in `ap_object.data` where nothing renders them.

  A type listed in `Bonfire.Social.APActivities`' `handle_object_types` is claimed as one we keep whole: the document becomes an `APActivity`, so a card can render it, and that claim beats any other module handling one of the document's other types.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  @actor "https://cuisine.local/api/ap/actor/1"
  @config_key [Bonfire.Social.APActivities, :handle_object_types]

  setup_all do
    mock_global(fn
      %{method: :get, url: @actor} ->
        json(Simulate.actor_json("https://mocked.local/users/karen") |> Map.put("id", @actor))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp recipe_doc do
    "../fixtures/cuisine.local-preparation.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp receive_doc(data) do
    {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)
    Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
  end

  describe "what gets stored as json" do
    # For a verb we model, the wrapper is already consumed before storing: addressing became
    # boundary/to_circles, and the verb became the Bonfire Activity's verb. Storing it again
    # duplicates what is modelled natively, and is what forces readers into
    # `e(json, "object", field) || e(json, field)`.
    test "a modelled verb stores the object it wrapped" do
      data = recipe_doc() |> Map.put("type", "XYZ")

      assert {:ok, object} = receive_doc(data)
      assert object.__struct__ == Bonfire.Data.Social.APActivity

      assert object.json["type"] == "XYZ", "json should be the object, not the Create around it"
      assert [%{"unit" => "g"} | _] = object.json["ingredients"]
      refute object.json["object"], "the wrapper should not have been stored too"
    end
  end

  describe "types nobody claims (unchanged behaviour)" do
    test "a single-type Note becomes a Post" do
      data = recipe_doc() |> Map.put("type", "Note")

      assert {:ok, object} = receive_doc(data)
      assert object.__struct__ == Bonfire.Data.Social.Post
    end

    test "a multi-type object still becomes a Post while nothing claims its other type" do
      data = recipe_doc() |> Map.put("type", ["Note", "XYZ"])

      assert {:ok, object} = receive_doc(data)
      assert object.__struct__ == Bonfire.Data.Social.Post
    end

    test "an unmodelled vocabulary is carried, not mangled" do
      # `ingredients` have no "type", and `steps` are "PreparationContent" which is not a `known_fetchable_type?`, so neither is fetched when storing nor resolved when rendering
      data = recipe_doc() |> Map.put("type", "XYZ")

      assert {:ok, object} = receive_doc(data)
      assert object.__struct__ == Bonfire.Data.Social.APActivity

      # deliberately shape-agnostic: whether json is the object or the activity around it is a
      # separate concern, asserted by "a modelled verb stores the object it wrapped"
      doc = object.json["object"] || object.json

      assert [%{"unit" => "g"} | _] = doc["ingredients"]
      assert [%{"type" => "PreparationContent"} | _] = doc["steps"]
    end
  end

  describe "a type claimed by APActivities" do
    setup do
      previous = Bonfire.Common.Config.get(@config_key, [])
      Bonfire.Common.Config.put(@config_key, ["XYZ"])
      ActivityPub.Utils.cache_clear()

      on_exit(fn ->
        Bonfire.Common.Config.put(@config_key, previous)
        ActivityPub.Utils.cache_clear()
      end)

      :ok
    end

    test "keeps the whole document, beating the module that handles its other type" do
      data = recipe_doc() |> Map.put("type", ["Note", "XYZ"])

      assert {:ok, object} = receive_doc(data)

      assert object.__struct__ == Bonfire.Data.Social.APActivity,
             "a claimed type must win over `Note` -> Posts, or the recipe half is lost"

      doc = object.json["object"] || object.json
      assert doc["serving"] == 6
      assert length(doc["ingredients"]) == 3
    end
  end

  describe "the types claimed out of the box" do
    test "a cuisine.social recipe is kept whole with no configuration" do
      assert "Preparation" in Bonfire.Social.APActivities.federation_module(),
             "`AP_HANDLE_OBJECT_TYPES` defaults to claiming Preparation, see Bonfire.Social.RuntimeConfig"

      assert {:ok, object} = receive_doc(recipe_doc())
      assert object.__struct__ == Bonfire.Data.Social.APActivity

      doc = object.json["object"] || object.json
      assert doc["serving"] == 6
    end

    # The recipe has no plain `name`, and its ingredients and steps carry their text one level down,
    # so the card depends on `Transformer.fix_language_maps/1` having derived all of them at ingest.
    test "its language maps are readable as plain properties" do
      assert {:ok, object} = receive_doc(recipe_doc())

      doc = object.json["object"] || object.json

      assert doc["name"] == "Salade de boulgour"
      assert doc["servingType"] == "personnes"
      assert [%{"name" => "Boulgour"}, %{"name" => "Lardons"} | _] = doc["ingredients"]
      assert [%{"content" => "Faire bouillir" <> _} | _] = doc["steps"]
    end
  end
end
