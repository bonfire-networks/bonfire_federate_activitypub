defmodule Bonfire.Federate.ActivityPub.Testing.MobilizonShapes do
  @moduledoc """
  The documents a Mobilizon group sends and serves about its members, built in the shapes Mobilizon's code produces, rehosted to `mobilizon.local` to match `fixtures/mobilizon/group_actor.json`. Each builder cites the Mobilizon source (commit f2590486f) its shape comes from; paths are under `lib/` of the Mobilizon checkout. A live run replaces these with captures.
  """

  @group "https://mobilizon.local/@framasoft"
  @members_url "#{@group}/members"
  @page_size 10

  def group, do: @group
  def members_url, do: @members_url
  def page_size, do: @page_size

  @doc "The group actor, from the captured fixture, with its openness (and member count) set."
  def group_actor(openness, member_count \\ 12) do
    __DIR__
    |> Path.join("../fixtures/mobilizon/group_actor.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(%{"openness" => openness, "memberCount" => member_count})
  end

  @doc "A person on the group's host, as Mobilizon names them (`federation/activity_stream/converter/actor.ex`: the actor's `url`, `/@name`)."
  def person(n), do: "https://mobilizon.local/@member#{n}"

  @doc "A Member URL, which Mobilizon builds as the instance URL, `/member/` and a uuid (`mobilizon/actors/member.ex:98`)."
  def member_url(n), do: "https://mobilizon.local/member/00000000-0000-4000-8000-#{pad(n)}"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(12, "0")

  @doc "A `Member`, the way Mobilizon converts one (`federation/activity_stream/converter/member.ex:26-34`): its `id` is the Member URL, which is the id of the `Join` that made it."
  def member(n, role \\ "member"), do: member_of(person(n), member_url(n), role)

  @doc "A `Member` for a person and Member URL of the caller's choosing, eg. a person of ours and the id of the `Join` we sent."
  def member_of(person_id, member_url, role \\ "member") do
    %{
      "type" => "Member",
      "id" => member_url,
      "actor" => person_id,
      "object" => @group,
      "role" => role
    }
  end

  @doc """
  The group's members collection and its pages as a signed member is served them.

  The root is an `OrderedCollection` with its first page inline (`web/views/activity_pub/actor_view.ex:65-79`), each page an `OrderedCollectionPage` of ten `Member` items (`:160-195` for the page, `:213` for the item), with a `next` link while the page's offset is below the total (so the last page with items links to one more, an empty page) and a `prev` once the offset is over it. Returns a map of URL to document.
  """
  def members_docs(members) do
    total = length(members)
    pages = last_page(total)

    page_docs = Map.new(1..pages, fn n -> {page_url(n), page(members, n, total)} end)

    Map.put(page_docs, @members_url, root(members, total))
  end

  @doc "What a non-member is served: Mobilizon answers an empty collection (`actor_view.ex:16,51-53,140-146`)."
  def members_docs_for_non_member do
    root = root([], 0)
    %{@members_url => root, page_url(1) => root["first"]}
  end

  # one page past the last with items, which is what Mobilizon links to
  defp last_page(total), do: div(total + @page_size - 1, @page_size) + 1

  defp page_url(n), do: "#{@members_url}?page=#{n}"

  defp root(members, total) do
    %{
      "id" => @members_url,
      "attributedTo" => @group,
      "type" => "OrderedCollection",
      "totalItems" => total,
      "first" => page(members, 1, total)
    }
  end

  defp page(members, n, total) do
    offset = (n - 1) * @page_size

    %{
      "id" => page_url(n),
      "attributedTo" => @group,
      "type" => "OrderedCollectionPage",
      "partOf" => @members_url,
      "orderedItems" => members |> Enum.drop(offset) |> Enum.take(@page_size)
    }
    |> then(&if(offset < total, do: Map.put(&1, "next", page_url(n + 1)), else: &1))
    |> then(&if(offset > total, do: Map.put(&1, "prev", page_url(n - 1)), else: &1))
  end

  @doc "A person joining the group, as Mobilizon sends it (`federation/activity_pub/types/actors.ex:177-181`, addressed as `activity_pub/audience.ex:97-99`): the id is the Member URL."
  def join(n) do
    %{
      "type" => "Join",
      "id" => member_url(n),
      "actor" => person(n),
      "object" => @group,
      "to" => [@group, @members_url],
      "cc" => []
    }
  end

  @doc """
  The group accepting a remote person's join to an open group (`activity_pub/actions/accept.ex:105-134`, built by `activity_pub/utils.ex:666-676`, and sent by the group as `activity_pub/types/actors.ex:268-272`): the object is the `Member`, with the Member URL as its id.
  """
  def accept_join(%{"type" => "Member", "id" => id} = member) do
    %{
      "type" => "Accept",
      "id" => "https://mobilizon.local/accept/join/#{Path.basename(id)}",
      "actor" => @group,
      "to" => [@group, @members_url],
      "cc" => nil,
      "object" => member
    }
  end

  @doc "A moderator accepting a join to a moderated group (`activity_pub/actions/accept.ex:168-204`)."
  def accept_member(%{"type" => "Member", "id" => id} = member, moderator) do
    %{
      "type" => "Accept",
      "id" => "https://mobilizon.local/accept/member/#{Path.basename(id)}",
      "attributedTo" => @group,
      "actor" => moderator,
      "to" => [@members_url],
      "cc" => [@group],
      "object" => member
    }
  end

  @doc "A moderator rejecting a join to a moderated group (`activity_pub/actions/reject.ex:131-143`): the object is the Member URL, which is the id of the `Join`."
  def reject_member(%{"type" => "Member", "id" => id}, moderator) do
    %{
      "type" => "Reject",
      "id" => "https://mobilizon.local/reject/member/#{Path.basename(id)}",
      "actor" => moderator,
      "attributedTo" => @group,
      "to" => [@members_url],
      "cc" => [@group],
      "object" => id
    }
  end

  @doc "A member leaving (`activity_pub/actions/leave.ex:90-97`)."
  def leave(person_id, id \\ nil) do
    %{
      "type" => "Leave",
      "id" => id || "https://mobilizon.local/leave/#{System.unique_integer([:positive])}",
      "actor" => person_id,
      "object" => @group,
      "to" => [@members_url],
      "cc" => [@group],
      "attributedTo" => @group
    }
  end

  @doc "A moderator removing a member (`activity_pub/actions/remove.ex:41-47`): the object is the Member URL, there is no `target`."
  def remove(moderator, member_url, removed_person) do
    %{
      "type" => "Remove",
      "id" => "https://mobilizon.local/remove/#{System.unique_integer([:positive])}",
      "actor" => moderator,
      "object" => member_url,
      "origin" => @group,
      "to" => [removed_person, @members_url]
    }
  end

  @doc "A moderator changing a member's role (`activity_pub/types/members.ex:53-62`, wrapped by `activity_pub/utils.ex:646-660`)."
  def update_member(%{"type" => "Member", "id" => id, "actor" => person} = member, moderator) do
    %{
      "type" => "Update",
      "id" => id <> "/activity",
      "actor" => moderator,
      "attributedTo" => [@group],
      "to" => [@members_url, person],
      "cc" => [@group],
      "object" => member
    }
  end
end
