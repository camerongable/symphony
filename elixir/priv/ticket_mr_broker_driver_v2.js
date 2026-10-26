(async function ticketMrBrokerDriver(runtime, input) {
  "use strict";
  const {tools, metadata} = runtime;
  const {mode, requestKey, automationId, expectedOldSha} = input;
  const cwd = "/Users/cgable/Repos/symphony-ticket-chat-implementation/elixir";
  const launcher = cwd + "/scripts/factory-broker";
  const workflow = "/Users/cgable/Repos/symphony/elixir/WORKFLOW.local.md";
  const resolver = "/Users/cgable/.agents/skills/broker-symphony-desktop-requests/scripts/read-broker-binding.py";
  const required = ["exec_command", "write_stdin", "mcp__codex_app__read_thread"];
  if (mode === "claim" || mode === "recover") required.push("mcp__codex_app__send_message_to_thread");
  if (!["preflight", "correct", "claim", "recover"].includes(mode)
      || !/^desktop:[0-9a-f]{64}$/.test(requestKey)
      || typeof automationId !== "string" || !automationId)
    throw new Error("MR_DRIVER_INPUT_INVALID");
  for (const name of required) {
    if (!metadata.some(t => t.name === name) || typeof tools[name] !== "function")
      throw new Error("MR_ORCHESTRATION_CAPABILITY_UNAVAILABLE");
  }
  const quote = value => "'" + String(value).replace(/'/g, "'\\''") + "'";
  async function shell(argv) {
    let result;
    try {
      result = await tools.exec_command({cmd: argv.map(quote).join(" "), workdir: cwd,
        yield_time_ms: 1000, max_output_tokens: 30000});
    } catch { throw new Error("CLI_OBSERVATION_UNCERTAIN"); }
    let output = result.output;
    const deadline = Date.now() + 90000;
    while (result.session_id != null) {
      if (Date.now() >= deadline || typeof output !== "string" || output.length > 1048576)
        throw new Error("CLI_OBSERVATION_UNCERTAIN");
      try {
        result = await tools.write_stdin({session_id: result.session_id, chars: "",
          yield_time_ms: 1000, max_output_tokens: 30000});
      } catch { throw new Error("CLI_OBSERVATION_UNCERTAIN"); }
      output += result.output;
    }
    if (result.exit_code !== 0) throw new Error("CLI_OBSERVATION_UNCERTAIN");
    if (typeof output !== "string" || output.length > 1048576)
      throw new Error("CLI_OUTPUT_INVALID");
    try { return JSON.parse(output); } catch { throw new Error("CLI_OUTPUT_INVALID"); }
  }
  const cli = args => shell([launcher, "desktop", ...args, "--workflow", workflow]);
  function envelope(raw) {
    if (!raw || raw.isError) throw new Error("OWNING_READ_FAILED");
    const candidates = [];
    if (raw.schemaVersion === 1 && raw.thread) candidates.push(raw);
    if (raw.structuredContent?.schemaVersion === 1 && raw.structuredContent.thread)
      candidates.push(raw.structuredContent);
    for (const item of raw.content || []) {
      if (item.type !== "text") continue;
      let parsed; try { parsed = JSON.parse(item.text); } catch { continue; }
      if (parsed?.schemaVersion === 1 && parsed.thread) candidates.push(parsed);
    }
    const unique = [...new Map(candidates.map(x => [JSON.stringify(x), x])).values()];
    if (unique.length !== 1) throw new Error("OWNING_ENVELOPE_MISSING_OR_AMBIGUOUS");
    return unique[0];
  }
  function base64Utf8(value) {
    const bytes = encodeURIComponent(JSON.stringify(value)).replace(/%([0-9A-F]{2})/g,
      (_, h) => String.fromCharCode(parseInt(h, 16)));
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let out = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2);
      out += alphabet[a >> 2] + alphabet[((a & 3) << 4) | (Number.isNaN(b) ? 0 : b >> 4)]
        + (Number.isNaN(b) ? "=" : alphabet[((b & 15) << 2) | (Number.isNaN(c) ? 0 : c >> 6)])
        + (Number.isNaN(c) ? "=" : alphabet[c & 63]);
    }
    return out;
  }
  const identity = await shell(["/opt/homebrew/bin/python3.13", resolver, automationId]);
  const broker = identity.broker_thread_id;
  if (identity.automation_id !== automationId || typeof broker !== "string" || !broker)
    throw new Error("BROKER_BINDING_UNPROVEN");
  const request = await cli(["show", requestKey]);
  let binding;
  try { binding = JSON.parse(request.metadata_json).delivery_operation; }
  catch { throw new Error("EXACT_UNISSUED_TYPED_REQUEST_UNPROVEN"); }
  const allowedState = mode === "recover"
    ? request.status === "FOLLOWUP_UNCERTAIN" && typeof request.claimed_at === "string" && !!request.claimed_at
    : request.status === "PENDING" && request.claimed_at == null;
  if (request.request_key !== requestKey || request.target_kind !== "CONTROLLER"
      || request.action !== "FOLLOWUP" || !allowedState
      || request.thread_id != null || request.turn_id != null
      || binding?.version !== 2 || binding.operation !== "CREATE_OR_REUSE_DRAFT_MR"
      || typeof request.existing_thread_id !== "string" || !request.existing_thread_id
      || broker === request.existing_thread_id
      || typeof request.prompt !== "string"
      || !request.prompt.startsWith("Factory request ID: " + requestKey + "\n")
      || typeof request.model !== "string" || !request.model
      || typeof request.reasoning_effort !== "string" || !request.reasoning_effort)
    throw new Error("EXACT_UNISSUED_TYPED_REQUEST_UNPROVEN");
  const expected = {threadId: request.existing_thread_id, model: request.model,
    thinking: request.reasoning_effort, prompt: request.prompt};
  const projected = JSON.stringify({request_key: requestKey, status: "FOLLOWUP_UNCERTAIN",
    arguments: expected}, null, 2).replace(/[\u007f-\uffff]/g,
    value => "\\u" + value.charCodeAt(0).toString(16).padStart(4, "0"));
  // A byte-token ceiling and framing margin keep the postcommit acknowledgement inside the requested tool budget.
  if (projected.length + 512 > 8192) throw new Error("MR_CLAIM_RESPONSE_BUDGET_EXCEEDED");
  const read = () => tools.mcp__codex_app__read_thread({threadId: expected.threadId,
    turnLimit: 1, includeOutputs: false});
  const probe = envelope(await read());
  if (probe.thread.id !== expected.threadId) throw new Error("OWNING_TARGET_MISMATCH");
  if (mode === "preflight") return {status: "MR_ORCHESTRATION_PREFLIGHT_PASS", request_key: requestKey};
  if (mode === "correct" && (!/^[0-9a-f]{64}$/.test(expectedOldSha)
      || request.payload_sha256 !== expectedOldSha)) throw new Error("CORRECTION_SHA_MISMATCH");
  const action = mode === "correct" ? "correction" : mode === "recover" ? "recovery" : "claim";
  async function observeSource() {
    if (mode !== "recover") return;
    const source = envelope(await tools.mcp__codex_app__read_thread({threadId: broker,
      includeOutputs: true, turnLimit: 1, maxOutputCharsPerItem: 500}));
    if (source.thread.id !== broker || source.thread.hostId !== "local"
        || source.thread.status?.type !== "active" || !Array.isArray(source.turns)
        || source.turns.length !== 1 || source.turns[0].status !== "inProgress"
        || source.turns[0].error !== null || source.turns[0].completedAt !== null)
      throw new Error("OWNING_SOURCE_ACTIVE_UNPROVEN");
  }
  const prepareArgs = ["prepare-ticket-mr-" + action, requestKey];
  if (mode === "correct") prepareArgs.push(expectedOldSha);
  prepareArgs.push("--source-thread-id", broker);
  await observeSource();
  const prepared = await cli(prepareArgs);
  if (prepared.status !== "MR_OWNER_ADMISSION_PREPARED" || prepared.request_key !== requestKey
      || prepared.action !== mode || prepared.payload_sha256 !== request.payload_sha256
      || !/^[0-9a-f]{64}$/.test(prepared.handle)
      || typeof prepared.expires_at !== "string" || !Number.isFinite(Date.parse(prepared.expires_at)))
    throw new Error("PREPARATION_RESULT_INVALID");
  const owner = envelope(await read());
  await observeSource();
  const observedAt = new Date().toISOString();
  if (owner.thread.id !== expected.threadId) throw new Error("OWNING_TARGET_MISMATCH");
  if (Date.parse(prepared.expires_at) <= Date.now()) throw new Error("MR_ADMISSION_BUDGET_EXHAUSTED");
  const frame = {request_key: requestKey, source_thread_id: broker,
    owner: {source: "codex_app/read_thread", observed_at: observedAt, response: owner}};
  const result = await cli(["finalize-ticket-mr-" + action, requestKey, prepared.handle,
    "--source-thread-id", broker, "--payload-base64", base64Utf8(frame)]);
  if (mode === "correct") {
    if (result.status !== "MR_ACTOR_CWD_CORRECTED" || result.request_key !== requestKey
        || result.original_payload_sha256 !== expectedOldSha) throw new Error("CORRECTION_RESULT_INVALID");
    return {status: result.status, request_key: requestKey};
  }
  if (!result || typeof result !== "object" || Array.isArray(result)
      || Object.keys(result).sort().join(",") !== "arguments,request_key,status"
      || result.status !== "FOLLOWUP_UNCERTAIN" || result.request_key !== requestKey
      || !result.arguments || Object.keys(result.arguments).sort().join(",") !== "model,prompt,thinking,threadId"
      || Object.keys(expected).some(key => result.arguments[key] !== expected[key]))
    throw new Error("COMMITTED_CLAIM_OUTPUT_INVALID");
  let sent;
  try { sent = await tools.mcp__codex_app__send_message_to_thread(result.arguments); }
  catch { throw new Error("SEND_RESULT_UNCERTAIN"); }
  if (!sent || typeof sent !== "object" || !Array.isArray(sent.content) || sent.isError)
    throw new Error("SEND_RESULT_UNCERTAIN");
  return {status: "MR_SEND_RETURNED", request_key: requestKey, target_thread_id: expected.threadId};
})
