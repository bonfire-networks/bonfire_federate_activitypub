defmodule Bonfire.Federate.ActivityPub.MisskeyMarkdownSanitiseTest do
  @moduledoc """
  A remote post whose `source.mediaType` says Misskey markdown (`text/x.misskeymarkdown`) is received with its HTML kept rather than stripped, so its formatting survives. The remote server chooses that flag, so it must not also let live markup (scripts, event handlers, `javascript:` links) into the stored post, whether it arrives in a `Create` or in a later `Update`.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  # the actor and its notes share a mocked host; links in the content use a real TLD, since link detection ignores `.local` hosts (mocked, so nothing leaves the machine)
  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  @payloads [
    "<script>alert(1)</script>",
    ~s|<img src="x" onerror="alert(1)">|,
    "[x](javascript:alert(1))",
    ~s|<a href="javascript:alert(1)">y</a>|
  ]

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @remote_actor <> "/followers"} ->
        json(%{})

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  defp note(id, content, extra \\ %{}) do
    Map.merge(
      %{
        "id" => @remote_instance <> "/notes/" <> id,
        "type" => "Note",
        "attributedTo" => @remote_actor,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "content" => content,
        "source" => %{"content" => content, "mediaType" => "text/x.misskeymarkdown"}
      },
      extra
    )
  end

  defp receive(type, note, suffix \\ "/activity") do
    assert {:ok, data} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => type,
               "id" => note["id"] <> suffix,
               "actor" => @remote_actor,
               "to" => note["to"],
               "object" => note
             })

    assert {:ok, post} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    post
  end

  defp stored(post_id) do
    repo().get!(Bonfire.Data.Social.PostContent, post_id)
  end

  # live markup only: a `javascript:` URL as plain text (eg. inside unconverted markdown) can't run, since remote bodies render with markdown skipped
  defp live_markup?(html) do
    html =~ ~r/<script/i or html =~ ~r/\son\w+\s*=/i or
      html =~ ~r/(href|src)\s*=\s*["']?\s*javascript:/i
  end

  defp refute_live_markup(html), do: refute(live_markup?(html), html)

  # the flag has no effect on remote content: remote bodies, titles and warnings are always sanitised (`PostContents.prepare_remote_content/3`), so markup the sanitiser strips (eg. a `div` with a class) is stripped with or without it
  test "a Misskey markdown post is sanitised like any remote post" do
    flagged = receive("Create", note("probe-flagged", ~s|<div class="test">kept</div>|))

    plain =
      receive(
        "Create",
        note("probe-plain", ~s|<div class="test">kept</div>|, %{"source" => nil})
      )

    assert stored(plain.id).html_body =~ "kept"
    refute stored(plain.id).html_body =~ "<div", "control: a plain remote post is sanitised"
    assert stored(flagged.id).html_body =~ "kept"
    refute stored(flagged.id).html_body =~ "<div"
  end

  # the control: the same flag with harmless formatting is received, and its formatting kept, so the tests below exercise the path that keeps HTML
  test "a Misskey markdown post keeps its harmless formatting" do
    post =
      receive(
        "Create",
        note(
          "control",
          ~s(<p><b>bold</b> and <a href="https://elsewhere.example.com/page">a link</a></p>)
        )
      )

    html = stored(post.id).html_body
    assert html =~ "<b>bold</b>"
    assert html =~ ~s(href="https://elsewhere.example.com/page")
  end

  test "a Misskey markdown post can't bring live markup in its body" do
    live =
      for {payload, i} <- Enum.with_index(@payloads),
          content <- ["<p>Hello #{payload} there</p>", "Hello #{payload} there"],
          post = receive("Create", note("body-#{i}-#{byte_size(content)}", content)),
          html = stored(post.id).html_body,
          live_markup?(html),
          do: html

    assert live == []
  end

  test "a Misskey markdown post can't bring live markup in its title or content warning" do
    payload = Enum.at(@payloads, 1)

    post =
      receive(
        "Create",
        note("fields", "<p>Hello there</p>", %{
          "name" => "Title #{payload}",
          "summary" => "Warning #{payload}"
        })
      )

    content = stored(post.id)
    assert content.html_body =~ "Hello"
    refute_live_markup(content.name || "")
    refute_live_markup(content.summary || "")
  end

  test "an Update of a Misskey markdown post can't bring live markup either" do
    note = note("updated", "<p>First version</p>")
    post = receive("Create", note)

    receive(
      "Update",
      Map.merge(note, %{
        "content" => "<p>Second version #{Enum.at(@payloads, 0)} #{Enum.at(@payloads, 1)}</p>",
        "updated" => DateTime.utc_now() |> DateTime.to_iso8601()
      }),
      "/update"
    )

    html = stored(post.id).html_body
    assert html =~ "Second version", "the update was applied"
    refute_live_markup(html)
  end
end
