defmodule SymphonyElixir.FactoryGenerationApplyTest do
  use ExUnit.Case, async: true

  test "generation text CAS uses its own creator receipt and the SELECT-only Factory WAL effect fence" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    lease = acquire_lease(ctx, 60)
    helper = Path.expand("../../priv/controller_generation_executor_v1.py", __DIR__)

    script = ~S"""
    import contextlib, hashlib, importlib.util, json, os, pathlib, sqlite3, sys, tempfile
    path = pathlib.Path(sys.argv[1]).resolve()
    spec = importlib.util.spec_from_file_location("generation", path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    def digest(raw): return hashlib.sha256(raw).hexdigest()
    with tempfile.TemporaryDirectory(prefix="generation-apply-") as directory:
      root = pathlib.Path(directory).resolve()
      source = root / "source"
      source.mkdir()
      target = source / "file.go"
      target.write_text("package before\n")
      database = pathlib.Path(sys.argv[2])
      writer = sqlite3.connect(database)
      assert writer.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
      assert writer.execute("SELECT max(version) FROM factory_schema_migrations").fetchone()[0] == 51
      columns = {table:{row[1] for row in writer.execute("PRAGMA table_info("+table+")")} for table in ("runs","control")}
      expected_tick = json.loads(sys.argv[3])
      tables = [row[0] for row in writer.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
      def rows(): return [(name,writer.execute('SELECT * FROM "'+name+'" ORDER BY 1').fetchall()) for name in tables]
      baseline = []
      recorded = []
      binding = {"root":str(source), "root_device":source.stat().st_dev, "root_inode":source.stat().st_ino,
        "invocation":"a"*64, "intent_key":"intent", "event_key":"event"}
      proposal = {"path":"file.go", "before_sha256":digest(target.read_bytes()),
        "after_sha256":digest(b"package after\n"), "content":"package after\n"}
      def creator(raw):
        value = json.loads(raw)
        assert value["kind"] == "CONTROLLER_GENERATION_TEMP_CREATED"
        assert value["pid"] == os.getpid() and value["invocation"] == "a"*64
        assert target.read_text() == "package before\n"
        writer.execute("INSERT INTO events (occurred_at,event_type,run_id,payload_json) VALUES ('fixture','TEST_GENERATION_CREATOR','run',?)",(raw.decode(),))
        writer.commit()
        recorded.append(value)
        baseline.append(rows())
      @contextlib.contextmanager
      def gate():
        with module.select_locked_role(str(database), columns) as role:
          module.tick_fence(role, expected_tick)
          assert role.execute("SELECT run_id FROM runs").fetchall() == [("run",)]
          called = []
          role.create_function("unauthorized_udf",0,lambda:called.append(True))
          for query in ("UPDATE runs SET state='BLOCKED'", "DELETE FROM runs", "CREATE TABLE forbidden(v)",
                        "ATTACH ':memory:' AS forbidden", "PRAGMA writable_schema=ON", "PRAGMA user_version=1",
                        "SELECT load_extension('forbidden')", "SELECT unauthorized_udf()", "SELECT * FROM desktop_requests"):
            try:
              role.execute(query)
              raise AssertionError("role escaped SELECT-only boundary")
            except sqlite3.DatabaseError:
              pass
          assert called == []
          competitor = sqlite3.connect(database, timeout=0.01)
          try:
            try:
              competitor.execute("INSERT INTO ticket_chat_commands (command_key,proposal_id,chat_key,run_id,binding_json,body_sha256,payload_json,payload_sha256,status,created_at,updated_at) SELECT 'race','race',chat_key,'run','{}','hash','{}','hash','PENDING','fixture','fixture' FROM ticket_chats LIMIT 1")
              competitor.commit()
              raise AssertionError("human input crossed effect fence")
            except sqlite3.OperationalError as error:
              assert str(error) == "database is locked"
            yield
          finally:
            competitor.close()
      result = module.replace_text(binding, proposal, creator, gate)
      assert result == {"path":"file.go", "sha256":proposal["after_sha256"]}
      assert target.read_text() == "package after\n"
      assert len(recorded) == 1
      assert list(source.iterdir()) == [target]
      assert rows() == baseline[0]
      writer.execute("BEGIN IMMEDIATE")
      writer.rollback()
      writer.close()
    print("text_cas=PASS; creator_before_effect=PASS; select_only_wal_fence=PASS; ledger_unchanged=PASS")
    """

    assert {"text_cas=PASS; creator_before_effect=PASS; select_only_wal_fence=PASS; ledger_unchanged=PASS\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, helper, ctx.database, Jason.encode!(lease)], stderr_to_stdout: true)
  end

  test "stale preimages and a denied post-creator fence never replace target bytes" do
    helper = Path.expand("../../priv/controller_generation_executor_v1.py", __DIR__)

    script = ~S"""
    import contextlib, hashlib, importlib.util, os, pathlib, sys, tempfile
    path = pathlib.Path(sys.argv[1]).resolve()
    spec = importlib.util.spec_from_file_location("generation", path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    def digest(raw): return hashlib.sha256(raw).hexdigest()
    with tempfile.TemporaryDirectory(prefix="generation-denial-") as directory:
      root = pathlib.Path(directory).resolve()
      target = root / "file.go"
      target.write_text("package original\n")
      binding = {"root":str(root), "root_device":root.stat().st_dev, "root_inode":root.stat().st_ino,
        "invocation":"b"*64, "intent_key":"intent", "event_key":"event"}
      proposal = {"path":"file.go", "before_sha256":"0"*64,
        "after_sha256":digest(b"package new\n"), "content":"package new\n"}
      recorded = []
      @contextlib.contextmanager
      def deny():
        raise ValueError("authorization_changed")
        yield
      for expected in ("0"*64, digest(target.read_bytes())):
        proposal["before_sha256"] = expected
        try:
          module.replace_text(binding, proposal, recorded.append, deny)
          raise AssertionError("unexpected replacement")
        except Exception:
          pass
        assert target.read_text() == "package original\n"
        assert list(root.iterdir()) == [target]
      assert len(recorded) == 1
    print("stale_preimage=DENIED; denied_effect_fence=DENIED; temporary_cleanup=OWNED_ONLY")
    """

    assert {"stale_preimage=DENIED; denied_effect_fence=DENIED; temporary_cleanup=OWNED_ONLY\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, helper], stderr_to_stdout: true)
  end

  test "an actual expired tick budget and a replaced tick cannot authorize a new text effect" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    short = acquire_lease(ctx, 1)
    helper = Path.expand("../../priv/controller_generation_executor_v1.py", __DIR__)

    script = ~S"""
    import importlib.util,json,pathlib,sqlite3,sys
    path=pathlib.Path(sys.argv[1]).resolve()
    spec=importlib.util.spec_from_file_location("generation",path)
    module=importlib.util.module_from_spec(spec)
    exec(compile(path.read_bytes(),str(path),"exec"),module.__dict__)
    database=sys.argv[2]
    expected=json.loads(sys.argv[3])
    connection=sqlite3.connect(database)
    columns={"control":[row[1] for row in connection.execute("PRAGMA table_info(control)")]}
    before=connection.execute("SELECT * FROM control ORDER BY scope").fetchall()
    try:
      with module.select_locked_role(database,columns) as role:
        module.tick_fence(role,expected)
      raise AssertionError("tick unexpectedly authorized")
    except ValueError as error:
      assert str(error)==sys.argv[4]
    assert connection.execute("SELECT * FROM control ORDER BY scope").fetchall()==before
    connection.close()
    print("tick_denied="+sys.argv[4])
    """

    python = System.find_executable("python3")
    assert {"tick_denied=generation_lease_unproven\n", 0} = System.cmd(python, ["-c", script, helper, ctx.database, Jason.encode!(short), "generation_lease_unproven"], stderr_to_stdout: true)
    config = %{scope: "generation-test", dispatcher_id: "fixture", lease_seconds: 60}
    assert %{result: "RELEASED"} = SymphonyElixir.Factory.Control.release_tick(ctx.store, config, "fixture", short["tick_id"])
    assert %{result: "ACQUIRED"} = SymphonyElixir.Factory.Control.acquire_tick(ctx.store, config, "fixture")
    assert {"tick_denied=generation_tick_changed\n", 0} = System.cmd(python, ["-c", script, helper, ctx.database, Jason.encode!(short), "generation_tick_changed"], stderr_to_stdout: true)
  end

  test "a human command arriving after durable creator acknowledgement fails the fresh locked snapshot before replacement" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    lease = acquire_lease(ctx, 60)
    helper = Path.expand("../../priv/controller_generation_executor_v1.py", __DIR__)

    script = ~S"""
    import contextlib,hashlib,json,pathlib,sqlite3,sys,tempfile,types
    path=pathlib.Path(sys.argv[1]).resolve()
    module=types.ModuleType("generation");module.__file__=str(path)
    exec(compile(path.read_bytes(),str(path),"exec"),module.__dict__)
    database=sys.argv[2];tick=json.loads(sys.argv[3]);connection=sqlite3.connect(database)
    columns={table:[row[1] for row in connection.execute("PRAGMA table_info("+table+")")] for table in module.READ_TABLES}
    binding={"database":database,"run_id":"run","scope":tick["scope"],"tick":tick,"ledger":{}}
    for name,(sql,parameter) in module.QUERIES.items():
      cursor=connection.execute(sql,(binding[parameter],))
      names=[item[0] for item in cursor.description]
      wanted=[name for name in names if name not in ("generation","tick_id","lease_expires_at","updated_at")] if name=="control" else names
      rows=[[row[names.index(column)] for column in wanted] for row in cursor.fetchall()]
      binding["ledger"][name]={"columns":wanted,"sha256":module.sha(module.compact([wanted,rows]))}
    with tempfile.TemporaryDirectory(prefix="generation-human-race-") as directory:
      root=pathlib.Path(directory).resolve();target=root/"job.go";target.write_text("package original\n")
      binding.update(root=str(root),root_device=root.stat().st_dev,root_inode=root.stat().st_ino,invocation="d"*64,intent_key="fixture",event_key="fixture-event")
      proposal={"path":"job.go","before_sha256":module.sha(target.read_bytes()),"after_sha256":module.sha(b"package generated\n"),"content":"package generated\n"}
      def creator(raw):
        assert json.loads(raw)["kind"]=="CONTROLLER_GENERATION_TEMP_CREATED"
        connection.execute("INSERT INTO ticket_chat_commands (command_key,proposal_id,chat_key,run_id,binding_json,body_sha256,payload_json,payload_sha256,status,created_at,updated_at) SELECT 'human-race','human-race',chat_key,'run','{}','hash','{}','hash','PENDING','fixture','fixture' FROM ticket_chats LIMIT 1")
        connection.commit()
        assert connection.execute("SELECT status FROM ticket_chat_commands WHERE command_key='human-race'").fetchone()==("PENDING",)
      @contextlib.contextmanager
      def fence():
        with module.select_locked_role(database,columns) as role:
          module.ledger_fence(role,binding)
          yield
      try:
        module.replace_text(binding,proposal,creator,fence)
        raise AssertionError("human command did not fence effect")
      except ValueError as error:
        assert str(error)=="generation_ledger_changed",str(error)
      assert target.read_text()=="package original\n"
      assert list(root.iterdir())==[target]
    connection.close()
    print("post_creator_human_command=DENIED; text_effect=ABSENT; temporary=OWNED_CLEANED")
    """

    assert {"post_creator_human_command=DENIED; text_effect=ABSENT; temporary=OWNED_CLEANED\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, helper, ctx.database, Jason.encode!(lease)], stderr_to_stdout: true)
  end

  defp acquire_lease(ctx, seconds) do
    alias SymphonyElixir.Factory.{Control, Store}
    config = %{scope: "generation-test", dispatcher_id: "fixture", lease_seconds: seconds}
    Control.initialize(ctx.store, config)
    assert {:ok, _} = Control.activate(ctx.store, config, "fixture")
    assert %{result: "ACQUIRED"} = Control.acquire_tick(ctx.store, config, "fixture")
    Store.one!(ctx.store, "SELECT * FROM control WHERE scope=?", [config.scope]) |> Map.take(~w(scope tick_id dispatcher_id lease_expires_at))
  end
end
