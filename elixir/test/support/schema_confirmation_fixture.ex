defmodule SymphonyElixir.SchemaConfirmationFixture do
  @moduledoc false

  def error do
    %{
      "message" => Jason.encode!(%{"status" => 400, "error" => %{"type" => "invalid_request_error", "code" => "invalid_json_schema", "param" => "text.format.schema"}}),
      "codexErrorInfo" => "other",
      "additionalDetails" => nil,
      "misalignment" => nil
    }
  end

  def install(ctx, old, prompt) do
    history = Path.join(ctx.root, "schema-history.sqlite")
    raw = Jason.encode!(error())
    item = Jason.encode!(%{"id" => "original", "type" => "userMessage", "content" => [%{"type" => "text", "text" => prompt}]})

    sql =
      "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,error_json TEXT,completed_at INTEGER,final_agent_item_id TEXT,rollout_end_ordinal INTEGER,rollout_byte_offset INTEGER,rollout_end_byte_offset INTEGER); CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,item_json TEXT);"

    values =
      "INSERT INTO thread_turns VALUES(#{quoted(old["thread_id"])},#{quoted(old["turn_id"])},1,'failed',#{quoted(raw)},#{DateTime.to_unix(DateTime.utc_now())},NULL,3,0,100); INSERT INTO thread_items VALUES(#{quoted(old["thread_id"])},#{quoted(old["turn_id"])},2,#{quoted(item)});"

    {_, 0} = System.cmd("sqlite3", [history, sql <> values])
    File.write!(history <> ".cwd", ctx.path)
    queue = Path.join(ctx.root, "schema-queue.sqlite")

    tables =
      "CREATE TABLE queued_items (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL, queue_order INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL); CREATE TABLE queued_thread_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL UNIQUE);"

    triggers =
      Enum.map_join([{"insert", "NEW"}, {"update", "NEW"}, {"delete", "OLD"}], fn {event, row} ->
        "CREATE TRIGGER queued_items_revision_after_#{event} AFTER #{String.upcase(event)} ON queued_items BEGIN INSERT INTO queued_thread_revisions (thread_id) VALUES (#{row}.thread_id) ON CONFLICT(thread_id) DO UPDATE SET revision = (SELECT COALESCE(MAX(revision),0)+1 FROM queued_thread_revisions); END;"
      end)

    {_, 0} = System.cmd("sqlite3", [queue, tables <> triggers])
    home = Path.join(ctx.root, "schema-home")
    File.mkdir_p!(Path.join(home, "thread-writer-locks"))

    rejection = %{
      "request_key" => old["request_key"],
      "turn_id" => old["turn_id"],
      "binding_sha256" => old["binding_sha256"],
      "evidence_sha256" => digest(Jason.encode!(old)),
      "native_error_sha256" => digest(raw),
      "authorization_reference" => "Explicit synthetic one-shot schema confirmation successor"
    }

    {rejection, [native_history: history, native_queue_database: queue, native_home: home, native_reader: __MODULE__]}
  end

  def read_native_thread(thread, opts) do
    history = opts[:native_history]
    {raw, 0} = System.cmd("sqlite3", ["-readonly", "-json", history, "SELECT turn_id,status,error_json FROM thread_turns ORDER BY rollout_ordinal DESC LIMIT 1;"])
    [turn] = Jason.decode!(raw)
    {items, 0} = System.cmd("sqlite3", ["-readonly", "-json", history, "SELECT item_json FROM thread_items ORDER BY rollout_ordinal;"])

    response = %{
      "data" => [%{"id" => turn["turn_id"], "status" => turn["status"], "error" => Jason.decode!(turn["error_json"]), "items" => Enum.map(Jason.decode!(items), &Jason.decode!(&1["item_json"]))}],
      "nextCursor" => nil
    }

    empty = %{"data" => [], "nextCursor" => nil}
    at = DateTime.to_iso8601(DateTime.utc_now())
    params = %{"threadId" => thread, "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}

    latest = %{
      "mode" => "LATEST_DESC",
      "parameters" => params,
      "raw_response" => response,
      "sha256" => digest(Jason.encode!(response)),
      "updated_at" => 1,
      "observed_at" => at,
      "confirmation" => %{"raw_response" => response, "sha256" => digest(Jason.encode!(response)), "observed_at" => at}
    }

    queue = %{"thread_id" => thread, "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false, "raw_response" => empty, "sha256" => digest(Jason.encode!(empty)), "observed_at" => at}
    result = %{"id" => thread, "cwd" => File.read!(history <> ".cwd"), "status" => %{"type" => "idle"}, "updatedAt" => 1, "latest_turn_observation" => latest, "queue_observation" => queue}
    {:ok, if(transform = Process.get(:schema_queue_transform), do: transform.(result), else: result)}
  end

  def replace_error(history, error) do
    raw = Jason.encode!(error)
    {_, 0} = System.cmd("sqlite3", [history, "UPDATE thread_turns SET error_json=#{quoted(raw)};"])
    digest(raw)
  end

  def unexpected_item(history, present) do
    sql =
      if present,
        do: "INSERT INTO thread_items SELECT thread_id,turn_id,4,'{\"type\":\"reasoning\"}' FROM thread_turns;",
        else: "DELETE FROM thread_items WHERE rollout_ordinal=4;"

    {_, 0} = System.cmd("sqlite3", [history, sql])
  end

  defp quoted(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
