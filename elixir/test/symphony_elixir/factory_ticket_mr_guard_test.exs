defmodule SymphonyElixir.FactoryTicketMrGuardTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketMrGuard

  @broker "00000000-0000-0000-0000-000000000001"

  setup do
    now = DateTime.utc_now()
    at = DateTime.to_iso8601(now)
    request = %{"existing_thread_id" => "controller", "cwd" => "/controller", "codex_project_id" => "project", "metadata_json" => Jason.encode!(%{"previous_turn_id" => "original"})}
    raw = %{"data" => [], "nextCursor" => nil}
    latest = %{"data" => [%{"id" => "original", "status" => "completed", "items" => []}], "nextCursor" => "older"}

    proof = %{
      "source_thread_id" => @broker,
      "owner" => %{
        "source" => "codex_app/read_thread",
        "observed_at" => at,
        "response" => %{"schemaVersion" => 1, "thread" => %{"id" => "controller", "cwd" => "/controller", "kind" => "codex", "hostId" => "local", "status" => %{"type" => "idle"}}}
      },
      "native" => %{
        "id" => "controller",
        "cwd" => "/controller",
        "projectId" => "project",
        "updatedAt" => 42,
        "queue_observation" => %{
          "thread_id" => "controller",
          "empty_complete" => true,
          "count_lower_bound" => 0,
          "has_more" => false,
          "observed_at" => at,
          "raw_response" => raw,
          "sha256" => digest(raw)
        },
        "latest_turn_observation" => %{
          "mode" => "LATEST_DESC",
          "parameters" => %{"threadId" => "controller", "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
          "raw_response" => latest,
          "sha256" => digest(latest),
          "confirmation" => %{"raw_response" => latest, "sha256" => digest(latest), "observed_at" => at},
          "updated_at" => 42,
          "observed_at" => at
        }
      }
    }

    %{request: request, proof: proof, now: now}
  end

  test "exact idle project controller, empty queue and original latest turn prove one guard", ctx do
    assert {:ok, receipt} = TicketMrGuard.receipt(ctx.request, ctx.proof, @broker, ctx.now)
    assert receipt["checked_at"] == DateTime.to_iso8601(ctx.now)
    assert receipt["native_sha256"] == digest(ctx.proof["native"])
    assert {:ok, _} = TicketMrGuard.receipt(ctx.request, put_in(ctx.proof, ["owner", "response", "thread", "status"], %{"type" => "notLoaded"}), @broker, ctx.now)
  end

  test "foreign, busy, incomplete, malformed and stale observations do not authorize claim", ctx do
    old = ctx.now |> DateTime.add(-11, :second) |> DateTime.to_iso8601()
    future = ctx.now |> DateTime.add(1, :second) |> DateTime.to_iso8601()
    latest = %{"data" => [%{"id" => "human-turn", "status" => "completed", "items" => []}], "nextCursor" => nil}
    human = ctx.proof |> put_in(["native", "latest_turn_observation", "raw_response"], latest) |> put_in(["native", "latest_turn_observation", "sha256"], digest(latest))

    for proof <- [
          Map.put(ctx.proof, "source_thread_id", "other"),
          Map.put(ctx.proof, "owner", nil),
          put_in(ctx.proof, ["owner", "response", "thread", "status"], %{"type" => "active"}),
          put_in(ctx.proof, ["owner", "response", "thread", "id"], "other"),
          put_in(ctx.proof, ["owner", "observed_at"], old),
          put_in(ctx.proof, ["owner", "observed_at"], nil),
          put_in(ctx.proof, ["native", "projectId"], "other"),
          put_in(ctx.proof, ["native", "cwd"], "/source"),
          put_in(ctx.proof, ["native", "queue_observation", "has_more"], true),
          put_in(ctx.proof, ["native", "queue_observation", "observed_at"], future),
          put_in(ctx.proof, ["native", "queue_observation", "observed_at"], false),
          put_in(ctx.proof, ["native", "queue_observation", "raw_response"], %{"data" => []}),
          put_in(ctx.proof, ["native", "queue_observation", "sha256"], "tampered"),
          put_in(ctx.proof, ["native", "latest_turn_observation"], nil),
          put_in(ctx.proof, ["native", "latest_turn_observation", "observed_at"], old),
          put_in(ctx.proof, ["native", "latest_turn_observation", "confirmation"], nil),
          put_in(ctx.proof, ["native", "latest_turn_observation", "confirmation", "observed_at"], old),
          put_in(ctx.proof, ["native", "latest_turn_observation", "confirmation", "raw_response"], latest),
          put_in(ctx.proof, ["native", "latest_turn_observation", "parameters", "sortDirection"], "asc"),
          put_in(ctx.proof, ["native", "updatedAt"], 43),
          put_in(ctx.proof, ["native", "latest_turn_observation", "raw_response", "data"], []),
          human
        ] do
      assert {:error, _} = TicketMrGuard.receipt(ctx.request, proof, @broker, ctx.now)
    end
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, Jason.encode!(raw)), case: :lower)
end
