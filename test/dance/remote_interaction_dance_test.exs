defmodule Bonfire.Federate.ActivityPub.Dance.RemoteInteractionTest do
  @moduledoc """
  E2e federation dance for the Mastodon-style "remote interaction" flow:

  A logged-out visitor on the local instance clicks Like on a public post.
  Because they are not authenticated, they are redirected to the
  `/remote_interaction` form. They enter the handle of their account on the
  *remote* dance instance and submit. The local instance performs a real
  cross-instance WebFinger against the running remote instance, reads its
  `http://ostatus.org/schema/1.0/subscribe` template, and redirects the
  visitor to the remote instance's interaction endpoint with the post's
  canonical URL substituted in.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle

  alias Bonfire.Posts

  # `conn/0` is imported from two modules via the dance case, so qualify it
  defp guest_conn, do: Bonfire.UI.Common.Testing.Helpers.conn()

  @tag :test_instance
  test "logged-out Like on a public post redirects to the remote interaction form, and submitting a remote handle WebFingers the remote instance",
       context do
    local_user = context[:local][:user]

    {:ok, post} =
      Posts.publish(
        current_user: local_user,
        post_attrs: %{post_content: %{html_body: "remote interaction dance post"}},
        boundary: "public"
      )

    canonical_url =
      Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)
      |> info("post canonical_url")

    # --- Part A: guest clicks Like -> redirected to the remote interaction form

    {:ok, view, _html} = live(guest_conn(), "/discussion/#{post.id}")

    # The Like button renders for guests (the auth check is in the handler,
    # not the template). Clicking it as a logged-out user must redirect.
    assert {:error, {kind, %{to: to}}} =
             view
             |> element("[data-role=like_enabled]")
             |> render_click()

    assert kind in [:redirect, :live_redirect]
    to = info(to, "redirected to")
    assert to =~ "/remote_interaction"
    assert to =~ "type=like"
    # `generate_url/4` interpolates the canonical URL raw into the query string
    assert to =~ canonical_url

    # The form page itself renders, carrying the object's canonical URL
    {:ok, _form_view, form_html} = live(guest_conn(), to)
    assert form_html =~ ~s(id="remote-interaction")
    assert form_html =~ canonical_url

    # --- Part B: submit a remote handle -> real cross-instance WebFinger

    remote_handle =
      context[:remote][:username]
      |> info("remote fediverse handle the guest enters")

    submit =
      guest_conn()
      # the form is a plain HTML POST through the :browser pipeline
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> post("/pub/remote_interaction", %{
        "outgoing" => %{
          "me" => remote_handle,
          "object" => canonical_url,
          "type" => "like"
        }
      })

    location =
      redirected_to(submit, 302)
      |> info("external redirect to the remote instance")

    remote_base =
      context[:remote][:canonical_url]
      |> URI.parse()
      |> then(&"#{&1.scheme}://#{&1.authority}")

    # The local instance fingered the remote instance, got its subscribe
    # template, and substituted `{uri}` with the post's canonical URL.
    assert String.starts_with?(location, remote_base),
           "expected redirect to the remote instance (#{remote_base}), got: #{location}"

    assert location =~ "/pub/remote_interaction?acct="
    assert location =~ canonical_url
  end
end
