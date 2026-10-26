defmodule SymphonyElixir.FactoryTicketCiReviewTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketCiReview

  defmodule Reader do
    def discussion_page(args, _opts) do
      send(self(), {:discussion_args, args})
      count = Process.get(:discussion_count, 0)
      Process.put(:discussion_count, count + 1)
      Process.get(:discussion_result).(args["page"], count)
    end
  end

  test "fresh complete stable review observations retain no comment bodies and explicit nonresolvable null is harmless" do
    note = %{"id" => "4015062336", "system" => true, "resolvable" => false, "body" => "UNRELATED_PRIVATE_COMMENT"}
    page = page([%{"id" => "discussion", "individual_note" => true, "notes" => [note]}])
    Process.put(:discussion_result, fn 1, _ -> {:ok, page} end)
    assert {:ok, observation} = TicketCiReview.observe(123, 42, connector: Reader)
    assert TicketCiReview.fresh?(observation)
    refute Jason.encode!(observation) =~ "UNRELATED_PRIVATE_COMMENT"
    assert_received {:discussion_args, %{"project_id" => "123", "merge_request_iid" => "42", "page" => 1, "per_page" => 100}}
    assert_received {:discussion_args, _}
  end

  test "active unresolved missing resolution drift unknown pagination and duplicate identities deny" do
    base = %{"id" => 7, "system" => false, "resolvable" => true, "resolved" => true}
    item = %{"id" => "thread", "individual_note" => false, "notes" => [base]}

    for changed <- [put_in(item, ["notes", Access.at(0), "resolved"], false), Map.put(item, "notes", [Map.delete(base, "resolved")]), Map.put(item, "notes", [base, base])] do
      Process.put(:discussion_result, fn 1, _ -> {:ok, page([changed])} end)
      assert {:error, _} = TicketCiReview.observe(123, 42, connector: Reader)
    end

    for changed <- [
          Map.delete(page([item]), "pagination"),
          put_in(page([item]), ["pagination", "x_total_pages"], 4),
          put_in(page([item]), ["pagination", "x_total"], 101),
          update_in(page([item]), ["pagination"], &Map.delete(&1, "x_next_page"))
        ] do
      Process.put(:discussion_result, fn 1, _ -> {:ok, changed} end)
      assert {:error, _} = TicketCiReview.observe(123, 42, connector: Reader)
    end

    Process.put(:discussion_count, 0)
    Process.put(:discussion_result, fn 1, count -> {:ok, if(count == 0, do: page([item]), else: page([]))} end)
    assert {:error, :ci_repair_discussions_changed} = TicketCiReview.observe(123, 42, connector: Reader)
    Process.put(:discussion_result, fn _, _ -> {:error, :mcp_tool_error} end)
    assert {:error, :mcp_tool_error} = TicketCiReview.observe(123, 42, connector: Reader)
  end

  test "complete bounded pagination covers every discussion before admitting quiet review state" do
    Process.put(:discussion_result, fn page, _ ->
      count = if page == 1, do: 100, else: 1
      offset = (page - 1) * 100

      items =
        for index <- (offset + 1)..(offset + count), do: %{"id" => "discussion-#{index}", "individual_note" => true, "notes" => [%{"id" => to_string(index), "system" => false, "resolvable" => false}]}

      {:ok, %{"items" => items, "pagination" => %{"x_page" => page, "x_per_page" => 100, "x_total" => 101, "x_total_pages" => 2, "x_next_page" => if(page == 1, do: "2", else: nil)}}}
    end)

    assert {:ok, %{"pages" => [_, _]}} = TicketCiReview.observe(123, 42, connector: Reader)
    assert Process.get(:discussion_count) == 4
  end

  defp page(items), do: %{"items" => items, "pagination" => %{"x_page" => 1, "x_per_page" => 100, "x_next_page" => nil, "x_total" => length(items), "x_total_pages" => 1}}
end
