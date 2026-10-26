defmodule SymphonyElixir.Factory.NativeQueueReadback do
  @moduledoc "Read-only persisted queue evidence under the sole-controller contract, not a global dispatch CAS."
  @tables %{
    "queued_items" =>
      "CREATE TABLE queued_items (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL, queue_order INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL)",
    "queued_thread_revisions" => "CREATE TABLE queued_thread_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL UNIQUE)"
  }
  @schema Map.merge(
            @tables,
            Map.new([{"insert", "NEW"}, {"update", "NEW"}, {"delete", "OLD"}], fn {event, row} ->
              name = "queued_items_revision_after_" <> event

              {name,
               "CREATE TRIGGER #{name} AFTER #{String.upcase(event)} ON queued_items BEGIN INSERT INTO queued_thread_revisions (thread_id) VALUES (#{row}.thread_id) ON CONFLICT(thread_id) DO UPDATE SET revision = (SELECT COALESCE(MAX(revision),0)+1 FROM queued_thread_revisions); END"}
            end)
          )

  @spec read(Path.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(database, thread) when is_binary(database) and is_binary(thread) do
    with true <- Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, thread),
         {:ok, stat} <- File.lstat(database),
         true <- stat.type == :regular,
         {raw, 0} <- System.cmd("/usr/bin/sqlite3", ["-readonly", "-json", database, sql(thread)], stderr_to_stdout: true),
         {:ok, [%{"schema_json" => schema_raw, "item_count" => 0, "revision" => revision}]} <- Jason.decode(raw),
         true <- is_integer(revision) and revision >= 0,
         {:ok, rows} <- Jason.decode(schema_raw),
         schema = Map.new(rows, &{&1["name"], normalize(&1["sql"])}),
         true <- schema == Map.new(@schema, fn {key, value} -> {key, normalize(value)} end),
         {:ok, after_stat} <- File.lstat(database),
         true <- identity(stat) == identity(after_stat) do
      {:ok, %{"thread_id" => thread, "database_path" => database, "database_identity" => identity(stat), "schema_sha256" => digest(schema), "revision" => revision, "item_count" => 0}}
    else
      _ -> {:error, :interrupted_persisted_queue_unproven}
    end
  end

  def read(_database, _thread), do: {:error, :interrupted_persisted_queue_unproven}

  @doc "Observes a free native writer lock read-only; never creates, deletes or retains the lock."
  @spec writer_unlocked(Path.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def writer_unlocked(home, thread) when is_binary(home) and is_binary(thread) do
    with true <- Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, thread),
         executable when is_binary(executable) <- System.find_executable("python3"),
         {raw, 0} <- System.cmd(executable, ["-c", lock_probe(), Path.join([home, "thread-writer-locks", thread <> ".lock"])], stderr_to_stdout: true),
         {:ok, proof} when is_map(proof) <- Jason.decode(raw) do
      {:ok, proof}
    else
      _ -> {:error, :interrupted_native_writer_lock_unproven}
    end
  end

  def writer_unlocked(_home, _thread), do: {:error, :interrupted_native_writer_lock_unproven}

  defp lock_probe do
    """
    import os, sys, fcntl, json, stat
    path = sys.argv[1]
    parent_path, name = os.path.split(path)
    parent = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        directory = os.fstat(parent)
        if not stat.S_ISDIR(directory.st_mode): raise RuntimeError('not directory')
        proof = {'path': path, 'parent_device': directory.st_dev, 'parent_inode': directory.st_ino}
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        except FileNotFoundError:
            try:
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                proof['status'] = 'absent'
            else:
                raise RuntimeError('absence changed')
        else:
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode): raise RuntimeError('not regular')
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                try:
                    after = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino): raise RuntimeError('changed')
                    proof.update(status='unlocked', device=before.st_dev, inode=before.st_ino)
                finally:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
        after_parent = os.stat(parent_path, follow_symlinks=False)
        if not stat.S_ISDIR(after_parent.st_mode) or (directory.st_dev, directory.st_ino) != (after_parent.st_dev, after_parent.st_ino): raise RuntimeError('parent changed')
        print(json.dumps(proof))
    finally:
        os.close(parent)
    """
  end

  defp sql(thread) do
    "SELECT (SELECT json_group_array(json_object('name',name,'sql',sql)) FROM sqlite_master WHERE name IN ('queued_items','queued_thread_revisions','queued_items_revision_after_insert','queued_items_revision_after_update','queued_items_revision_after_delete')) AS schema_json,(SELECT COUNT(*) FROM queued_items WHERE thread_id='#{thread}') AS item_count,COALESCE((SELECT revision FROM queued_thread_revisions WHERE thread_id='#{thread}'),0) AS revision;"
  end

  defp identity(stat), do: %{"device" => stat.major_device, "inode" => stat.inode}
  defp normalize(sql), do: sql |> String.replace(~r/\s+/, "") |> String.downcase() |> String.trim_trailing(";")
  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
