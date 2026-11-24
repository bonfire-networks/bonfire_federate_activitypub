defmodule Bonfire.Federate.ActivityPub.IncomingXSSTest do
  @moduledoc """
  What a remote server sends is text and links, never markup that runs in our pages: custom emoji addresses, actor names and the fields of object types we have no native type for are shown, but never become an attribute or a tag of their own.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  @remote_actor "https://mocked.local/users/karen"
  @name_actor "https://mocked.local/users/xssname"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @name_actor} ->
        json(
          Simulate.actor_json(@name_actor, "xssname", %{
            "name" => "&lt;img src=x onerror=alert(1)&gt;"
          })
        )

      %{method: :get, url: "https://mocked.local/.well-known/" <> _} ->
        %Tesla.Env{status: 404, body: ""}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  setup do
    account = fake_account!()
    me = fake_user!(account)
    %{me: me, conn: conn(user: me, account: account)}
  end

  # an S2S Create of `object`, as the inbox worker passes it on
  defp receive_create(object) do
    object = Map.merge(%{"attributedTo" => @remote_actor, "to" => [@public]}, object)

    {:ok, data} =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "id" => "#{object["id"]}/create",
        "actor" => @remote_actor,
        "to" => [@public],
        "object" => object
      })

    Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
  end

  defp object_id(), do: "https://mocked.local/objects/" <> Needle.UID.generate()

  describe "custom emoji" do
    defp note_with_emoji(url) do
      %{
        "id" => object_id(),
        "type" => "Note",
        "content" => "<p>hi :zzmoji: there</p>",
        "published" => "2015-02-10T15:00:00Z",
        "tag" => [
          %{
            "type" => "Emoji",
            "name" => ":zzmoji:",
            "icon" => %{"type" => "Image", "url" => url}
          }
        ]
      }
    end

    test "control: an emoji with a normal address renders as an image with that src", %{
      conn: conn
    } do
      assert {:ok, post} = receive_create(note_with_emoji("https://h.local/e.png"))

      conn
      |> visit(Bonfire.Common.URIs.path(post))
      |> wait_async()
      |> assert_has("[data-id=main_section] img[src='https://h.local/e.png']")
    end

    test "an emoji address with a quote does not add an event handler attribute", %{conn: conn} do
      assert {:ok, post} =
               receive_create(note_with_emoji("https://h.local/e.png' onerror='alert(1)"))

      conn
      |> visit(Bonfire.Common.URIs.path(post))
      |> wait_async()
      # the post itself is shown
      |> assert_has("[data-id=main_section]", text: "hi")
      |> refute_has("[data-id=main_section] [onerror*='alert(1)']")
    end
  end

  describe "actor name" do
    setup do
      {:ok, user} =
        Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(@name_actor)

      %{remote_user: repo().preload(user, :profile, force: true)}
    end

    test "entity-encoded markup in a remote actor's name is stored as plain text", %{
      remote_user: remote_user
    } do
      # a name is plain text (tags stripped, entities decoded); every place that shows it escapes it
      assert remote_user.profile.name == "<img src=x onerror=alert(1)>"
    end

    test "entity-encoded markup in a remote actor's name does not render a live tag on their profile",
         %{remote_user: remote_user, conn: conn} do
      conn
      |> visit(Bonfire.Common.URIs.path(remote_user))
      |> wait_async()
      |> refute_has("img[src='x']")
      |> refute_has("[onerror*='alert(1)']")
    end

    test "entity-encoded markup in a remote actor's name does not render a live tag on their profile card",
         %{remote_user: remote_user} do
      doc =
        render_component(&Bonfire.UI.Me.ProfileItemLive.render/1, %{
          profile: remote_user.profile,
          character: repo().preload(remote_user, :character, force: true).character,
          __context__: %{}
        })
        |> Floki.parse_fragment!()

      assert Floki.find(doc, "img[src=x]") == []

      # the avatar image has its own fixed fallback `onerror`; only a handler carrying the payload is a hole
      assert Floki.find(doc, "[onerror*='alert(1)']") == []
    end
  end

  describe "title and summary of a remote post or article" do
    for type <- ["Note", "Article"], field <- ["name", "summary"] do
      test "entity-encoded markup in a #{type}'s #{field} shows as text, not as a tag", %{
        conn: conn
      } do
        assert {:ok, object} =
                 receive_create(%{
                   "id" => object_id(),
                   "type" => unquote(type),
                   unquote(field) => "&lt;script&gt;alert(1)&lt;/script&gt; Safe",
                   "content" => "<p>a perfectly fine body</p>",
                   "published" => "2015-02-10T15:00:00Z"
                 })

        conn
        |> visit(Bonfire.Common.URIs.path(object))
        |> wait_async()
        |> assert_has("[data-id=main_section]", text: "Safe")
        |> refute_has("[data-id=main_section] [data-role=#{unquote(field)}] script")
      end

      test "markup in a #{type}'s #{field} is removed (control)", %{conn: conn} do
        assert {:ok, object} =
                 receive_create(%{
                   "id" => object_id(),
                   "type" => unquote(type),
                   unquote(field) => "<script>alert(1)</script>Safe",
                   "content" => "<p>a perfectly fine body</p>",
                   "published" => "2015-02-10T15:00:00Z"
                 })

        conn
        |> visit(Bonfire.Common.URIs.path(object))
        |> wait_async()
        |> assert_has("[data-id=main_section]", text: "Safe")
        |> refute_has("[data-id=main_section] [data-role=#{unquote(field)}] script")
      end
    end
  end

  describe "object types without a native type" do
    for type <- ["Event", "Audio"] do
      test "control: a benign #{type} shows its name", %{conn: conn} do
        assert {:ok, object} =
                 receive_create(%{
                   "id" => object_id(),
                   "type" => unquote(type),
                   "name" => "A perfectly fine name",
                   "content" => "<p>a perfectly fine body</p>",
                   "startTime" => "2030-01-01T10:00:00Z",
                   "published" => "2015-02-10T15:00:00Z"
                 })

        conn
        |> visit(Bonfire.Common.URIs.path(object))
        |> wait_async()
        |> assert_has("[data-id=main_section]", text: "A perfectly fine name")
      end

      test "a #{type} with markup in its name and content shows no live tag or handler", %{
        conn: conn
      } do
        assert {:ok, object} =
                 receive_create(%{
                   "id" => object_id(),
                   "type" => unquote(type),
                   "name" => "<img src=x onerror=alert(1)>",
                   "content" => "<img src=x onerror=alert(2)>",
                   "startTime" => "2030-01-01T10:00:00Z",
                   "published" => "2015-02-10T15:00:00Z"
                 })

        conn
        |> visit(Bonfire.Common.URIs.path(object))
        |> wait_async()
        |> refute_has("[onerror*='alert(']")
      end
    end
  end
end
