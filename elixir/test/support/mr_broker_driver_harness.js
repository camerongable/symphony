"use strict";
const config = JSON.parse(Buffer.from(process.argv[2], "base64").toString("utf8"));
const run = Function("return " + config.driver.source)();
const key = "desktop:" + "a".repeat(64);
const broker = "00000000-0000-0000-0000-000000000001";
const target = "00000000-0000-0000-0000-000000000002";
const request = config.request || {request_key: key, target_kind: "CONTROLLER", action: "FOLLOWUP",
  status: "PENDING", existing_thread_id: target, model: "gpt-6.1-sol", reasoning_effort: "high",
  prompt: "Factory request ID: " + key + "\nUnicode \u00e9 \ud83d\ude00 \\\"\n",
  payload_sha256: "b".repeat(64), metadata_json: JSON.stringify({delivery_operation:
    {version: 2, operation: "CREATE_OR_REUSE_DRAFT_MR"}})};
const counts = {prepare: 0, finalize: 0, send: 0, read: 0};
const observed = [];
const mode = config.mode || "claim";
const scenario = config.scenario || "valid";
const expected = {threadId: request.existing_thread_id, model: request.model,
  thinking: request.reasoning_effort, prompt: request.prompt};
let compact = config.compact || {request_key: request.request_key, status: "FOLLOWUP_UNCERTAIN", arguments: expected};
if (scenario === "wrong_target") compact.arguments = {...expected, threadId: broker};
if (scenario === "wrong_prompt") compact.arguments = {...expected, prompt: expected.prompt + "x"};
if (scenario === "wrong_model") compact.arguments = {...expected, model: "other"};
if (scenario === "wrong_effort") compact.arguments = {...expected, thinking: "low"};
if (scenario === "extra_argument") compact.arguments = {...expected, hostId: "local"};
if (scenario === "extra_row_field") compact = {...compact, existing_thread_id: target};
if (scenario === "missing_key") delete compact.request_key;
if (scenario === "missing_send_tool") delete compact.unused;
const cli = argv => {
  if (argv.includes("read-broker-binding.py")) return {automation_id: "fixture", broker_thread_id: broker};
  const action = argv[2];
  if (action === "show") return request;
  if (action.startsWith("prepare-ticket-mr-")) {
    counts.prepare++;
    return {status: "MR_OWNER_ADMISSION_PREPARED", request_key: request.request_key, action: mode,
      payload_sha256: request.payload_sha256, handle: "c".repeat(64),
      expires_at: new Date(Date.now() + (scenario === "expired" ? -1000 : 60000)).toISOString()};
  }
  if (action.startsWith("finalize-ticket-mr-")) {
    counts.finalize++;
    const frame = JSON.parse(Buffer.from(argv[argv.indexOf("--payload-base64") + 1], "base64").toString("utf8"));
    if (frame.owner.response.thread.id !== request.existing_thread_id || frame.source_thread_id !== broker)
      throw new Error("TEST_FRAME_BINDING_INVALID");
    if (scenario === "lost_finalize") throw new Error("transport lost after commit");
    if (mode === "correct") return {status: "MR_ACTOR_CWD_CORRECTED", request_key: request.request_key,
      original_payload_sha256: request.payload_sha256};
    return compact;
  }
  throw new Error("TEST_UNKNOWN_COMMAND");
};
const tools = {
  exec_command: async ({cmd}) => {
    const argv = [...cmd.matchAll(/'((?:[^']|'\\'')*)'/g)].map(m => m[1].replace(/'\\''/g, "'"));
    observed.push(argv.slice(0, 3));
    const value = argv[1]?.endsWith("read-broker-binding.py")
      ? {automation_id: "fixture", broker_thread_id: broker} : cli(argv);
    if (scenario === "reader_rejected" && argv[2]?.startsWith("finalize-ticket-mr-"))
      return {output: 'Factory runtime exchange failed: ":mr_owner_admission_unavailable"\n', exit_code: 1};
    return {output: JSON.stringify(value), exit_code: 0};
  },
  write_stdin: async () => { throw new Error("TEST_UNEXPECTED_POLL"); },
  mcp__codex_app__read_thread: async args => {
    counts.read++;
    if (args.threadId === broker) return {schemaVersion: 1,
      thread: {id: broker, hostId: "local", status: {type: scenario === "source_interrupted" ? "idle" : "active"}},
      turns: [{id: "recovery-turn", status: "inProgress", error: null, completedAt: null}]};
    return {schemaVersion: 1, thread: {id: scenario === "wrong_owner" ? broker : request.existing_thread_id}};
  },
  mcp__codex_app__send_message_to_thread: async args => {
    counts.send++;
    if (JSON.stringify(args) !== JSON.stringify(compact.arguments)) throw new Error("TEST_ARGUMENTS_CHANGED");
    return scenario === "send_error" ? {isError: true} : {isError: false, content: []};
  }
};
if (scenario === "missing_send_tool") delete tools.mcp__codex_app__send_message_to_thread;
const metadata = Object.keys(tools).map(name => ({name}));
run({tools, metadata}, {mode, requestKey: request.request_key, automationId: "fixture",
  expectedOldSha: request.payload_sha256})
  .then(result => process.stdout.write(JSON.stringify({result, counts})))
  .catch(error => process.stdout.write(JSON.stringify({error: error.message, counts})));
