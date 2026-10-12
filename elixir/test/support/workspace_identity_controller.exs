alias SymphonyElixir.Factory.{Store, WorkspaceAccess}

[database, encoded_attrs] = System.argv()
attrs = encoded_attrs |> Base.decode64!() |> Jason.decode!()
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_link(database: database)

result =
  with {:ok, acquired} <- WorkspaceAccess.acquire(store, attrs),
       {:ok, validated} <- WorkspaceAccess.validate(store, attrs["reservation_key"], 1) do
    %{"acquired" => acquired, "validated" => validated}
  else
    {:error, reason} -> %{"error" => inspect(reason)}
  end

IO.puts(Jason.encode!(result))
