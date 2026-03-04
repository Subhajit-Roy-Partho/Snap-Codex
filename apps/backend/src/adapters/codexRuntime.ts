import {
  type ChildProcessWithoutNullStreams,
  spawn,
  spawnSync
} from "node:child_process";
import { randomUUID } from "node:crypto";
import { createInterface, type Interface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import type {
  ChatSession,
  CollaborationMode,
  Model,
  PermissionProfile,
  Project,
  ReasoningEffort
} from "@codex/contracts";
import { PLAN_MODE_DEVELOPER_INSTRUCTIONS } from "../services/planModeInstructions.js";

export type RuntimeEventHandlers = {
  onToolStarted: (toolName: string, inputSummary: string) => void;
  onToolCompleted: (
    toolName: string,
    success: boolean,
    outputSummary: string
  ) => void;
  onTurnDiff: (turnId: string, diff: string) => void;
  onPermissionRequested: (requestId: string, prompt: string) => void;
  onDelta: (messageId: string, delta: string) => void;
  onCompleted: (messageId: string, content: string) => void;
  onUserInputRequested: (
    requestId: string,
    questions: UserInputQuestion[]
  ) => void;
  onStateChange: (status: ChatSession["status"]) => void;
  onError: (code: string, message: string) => void;
};

export type MessageRuntimeContext = {
  project: Project;
  profile: PermissionProfile;
  modelId: string;
  collaborationMode: CollaborationMode;
  reasoningEffort: ReasoningEffort;
  requestPermission: boolean;
};

export type UserInputQuestion = {
  header: string;
  id: string;
  question: string;
  options: Array<{
    label: string;
    description: string;
  }>;
};

export type RuntimeThreadHistoryItem = {
  threadId: string;
  preview: string;
  cwd: string | null;
  createdAt: string;
  updatedAt: string;
  status: string;
};

export type RuntimeThreadListResult = {
  data: RuntimeThreadHistoryItem[];
  nextCursor: string | null;
};

export type RuntimeThreadMessage = {
  role: "user" | "assistant" | "system" | "tool";
  content: string;
};

export type RuntimeHealth = {
  ready: boolean;
  mode: string;
  transport: string;
  command: string;
  args: string[];
  version: string | null;
  lastCheckedAt: string;
  checks: Array<{
    name: string;
    ok: boolean;
    message: string;
  }>;
  error: string | null;
};

export type CodexRuntime = {
  sendMessage: (
    session: ChatSession,
    content: string,
    context: MessageRuntimeContext,
    handlers: RuntimeEventHandlers
  ) => Promise<void>;
  interrupt: (sessionId: string) => Promise<void>;
  resolvePermission: (
    sessionId: string,
    requestId: string,
    approved: boolean
  ) => Promise<void>;
  listModels: () => Promise<Model[]>;
  listThreads: (params: {
    cwd?: string;
    cursor?: string;
    limit?: number;
  }) => Promise<RuntimeThreadListResult>;
  readThreadMessages: (threadId: string) => Promise<RuntimeThreadMessage[]>;
  resumeThread: (threadId: string) => Promise<void>;
  respondUserInput: (
    sessionId: string,
    requestId: string,
    answers: Record<string, { answers: string[] }>
  ) => Promise<void>;
  healthCheck: () => Promise<RuntimeHealth>;
  shutdown: () => Promise<void>;
};

type PendingRpcRequest = {
  method: string;
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
};

type SessionBinding = {
  threadId?: string;
  threadLoaded?: boolean;
  activeTurnId?: string;
  activeAssistantItemId?: string;
  expectedCollaborationMode?: CollaborationMode;
  planFallbackActive?: boolean;
  nativePlanProbeCompleted?: boolean;
  activePlanProbe?: {
    turnId: string;
    sawProposedPlanTag: boolean;
    requestedUserInput: boolean;
    askedClarifyingQuestion: boolean;
  };
};

type SessionTurnWaiter = {
  turnId: string;
  resolve: () => void;
  reject: (error: Error) => void;
};

type PendingApproval = {
  sessionId: string;
  rpcRequestId: string | number;
  kind: "command" | "file";
};

type PendingUserInput = {
  sessionId: string;
  rpcRequestId: string | number;
};

type ThreadExecutionPolicy = {
  approvalPolicy: "on-request" | "never" | "untrusted";
  sandbox: "read-only" | "workspace-write" | "danger-full-access";
};

type TurnExecutionOverride = {
  approvalPolicy: ThreadExecutionPolicy["approvalPolicy"];
  sandboxPolicy?: Record<string, unknown>;
};

const mapExecutionPolicyToTurnOverride = (
  executionPolicy: ThreadExecutionPolicy
): TurnExecutionOverride => {
  if (executionPolicy.sandbox === "danger-full-access") {
    return {
      approvalPolicy: executionPolicy.approvalPolicy,
      sandboxPolicy: { type: "dangerFullAccess" }
    };
  }

  return {
    approvalPolicy: executionPolicy.approvalPolicy
  };
};

const mapProfileToExecutionPolicy = (
  profileId: string,
  requestPermission: boolean
): ThreadExecutionPolicy => {
  if (profileId === "yolo") {
    return {
      approvalPolicy: "never",
      sandbox: "danger-full-access"
    };
  }

  if (requestPermission) {
    return {
      approvalPolicy: "on-request",
      sandbox: "workspace-write"
    };
  }

  if (profileId === "xhigh") {
    return {
      approvalPolicy: "on-request",
      sandbox: "read-only"
    };
  }

  return {
    approvalPolicy: "on-request",
    sandbox: "workspace-write"
  };
};

const makeCollaborationModePayload = (
  mode: CollaborationMode,
  modelId: string,
  reasoningEffort: ReasoningEffort,
  usePlanFallback: boolean
): Record<string, unknown> => ({
  mode,
  settings: {
    model: modelId,
    reasoning_effort: reasoningEffort,
    developer_instructions:
      mode === "plan" && usePlanFallback ? PLAN_MODE_DEVELOPER_INSTRUCTIONS : null
  }
});

const parseModeKind = (value: unknown): CollaborationMode | null => {
  const normalized = safeString(value).trim().toLowerCase();
  if (normalized === "plan" || normalized === "default") {
    return normalized;
  }

  return null;
};

const containsPlanModeFallbackSignal = (message: string): boolean => {
  const normalized = message.toLowerCase();
  return (
    (normalized.includes("request_user_input") &&
      normalized.includes("unavailable") &&
      normalized.includes("default mode")) ||
    normalized.includes("you are now in default mode")
  );
};

const endsWithQuestion = (content: string): boolean => content.trim().endsWith("?");

const safeString = (value: unknown): string => {
  if (typeof value === "string") {
    return value;
  }

  if (value === null || value === undefined) {
    return "";
  }

  if (typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }

  return String(value);
};

const hasRecordShape = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const DEFAULT_RUNTIME_MODELS: Model[] = [
  {
    id: "gpt-5-codex",
    displayName: "gpt-5-codex",
    capabilities: ["tool-use", "code", "reasoning"],
    defaultProfileIds: ["xhigh", "yolo"],
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
    defaultReasoningEffort: "medium"
  },
  {
    id: "gpt-5.3-codex",
    displayName: "gpt-5.3-codex",
    capabilities: ["tool-use", "code", "reasoning"],
    defaultProfileIds: ["xhigh", "yolo"],
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
    defaultReasoningEffort: "medium"
  },
  {
    id: "gpt-5.2-codex",
    displayName: "gpt-5.2-codex",
    capabilities: ["tool-use", "code", "reasoning"],
    defaultProfileIds: ["xhigh", "yolo"],
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
    defaultReasoningEffort: "medium"
  },
  {
    id: "gpt-5.2",
    displayName: "gpt-5.2",
    capabilities: ["chat", "code", "reasoning"],
    defaultProfileIds: ["xhigh", "yolo"],
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
    defaultReasoningEffort: "medium"
  }
];

export class MockCodexRuntime implements CodexRuntime {
  private readonly pendingPermissions = new Map<
    string,
    { requestId: string; resolve: (approved: boolean) => void }
  >();

  async sendMessage(
    session: ChatSession,
    content: string,
    context: MessageRuntimeContext,
    handlers: RuntimeEventHandlers
  ): Promise<void> {
    const assistantMessageId = randomUUID();
    handlers.onStateChange("running");
    handlers.onToolStarted("project_read", context.project.path);
    await delay(150);
    handlers.onToolCompleted("project_read", true, "Workspace indexed");

    if (context.requestPermission || context.profile.guardrails.requirePermissionPrompts) {
      const requestId = randomUUID();
      handlers.onStateChange("awaiting_permission");
      handlers.onPermissionRequested(
        requestId,
        "Allow Codex to execute shell commands in this session?"
      );

      const approved = await new Promise<boolean>((resolve) => {
        this.pendingPermissions.set(session.id, { requestId, resolve });
      });

      if (!approved) {
        handlers.onStateChange("cancelled");
        handlers.onError("permission_denied", "Permission denied by client.");
        return;
      }

      handlers.onStateChange("running");
    }

    const response = `Mock assistant response (${context.modelId}/${context.profile.id}/${context.collaborationMode}): ${content}`;
    const words = response.split(" ");
    let built = "";

    for (const word of words) {
      const deltaChunk = built.length === 0 ? word : ` ${word}`;
      built += deltaChunk;
      handlers.onDelta(assistantMessageId, deltaChunk);
      await delay(50);
    }

    handlers.onCompleted(assistantMessageId, built);
    handlers.onStateChange("completed");
  }

  async interrupt(sessionId: string): Promise<void> {
    const pending = this.pendingPermissions.get(sessionId);
    if (pending) {
      pending.resolve(false);
      this.pendingPermissions.delete(sessionId);
    }
  }

  async resolvePermission(
    sessionId: string,
    requestId: string,
    approved: boolean
  ): Promise<void> {
    const pending = this.pendingPermissions.get(sessionId);
    if (!pending || pending.requestId !== requestId) {
      return;
    }

    this.pendingPermissions.delete(sessionId);
    pending.resolve(approved);
  }

  async listModels(): Promise<Model[]> {
    return DEFAULT_RUNTIME_MODELS;
  }

  async listThreads(_params: {
    cwd?: string;
    cursor?: string;
    limit?: number;
  }): Promise<RuntimeThreadListResult> {
    return {
      data: [],
      nextCursor: null
    };
  }

  async resumeThread(_threadId: string): Promise<void> {}

  async readThreadMessages(_threadId: string): Promise<RuntimeThreadMessage[]> {
    return [];
  }

  async respondUserInput(
    _sessionId: string,
    _requestId: string,
    _answers: Record<string, { answers: string[] }>
  ): Promise<void> {}

  async healthCheck(): Promise<RuntimeHealth> {
    const checkedAt = new Date().toISOString();

    return {
      ready: true,
      mode: "mock",
      transport: "in-memory",
      command: "mock",
      args: [],
      version: "mock",
      lastCheckedAt: checkedAt,
      checks: [{ name: "runtime", ok: true, message: "Mock runtime is active." }],
      error: null
    };
  }

  async shutdown(): Promise<void> {
    this.pendingPermissions.clear();
  }
}

export class AppServerCodexRuntime implements CodexRuntime {
  private process: ChildProcessWithoutNullStreams | null = null;
  private stdoutReader: Interface | null = null;
  private nextRpcId = 1;
  private readonly pendingRequests = new Map<number, PendingRpcRequest>();
  private readonly sessionBindings = new Map<string, SessionBinding>();
  private readonly threadToSession = new Map<string, string>();
  private readonly sessionHandlers = new Map<string, RuntimeEventHandlers>();
  private readonly sessionTurnWaiters = new Map<string, SessionTurnWaiter>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private readonly pendingUserInputs = new Map<string, PendingUserInput>();

  private startPromise: Promise<void> | null = null;
  private ready = false;
  private lastError: string | null = null;
  private lastStderr = "";
  private version: string | null = null;
  private lastCheckedAt = new Date().toISOString();

  constructor(
    private readonly command: string,
    private readonly baseArgs: string[]
  ) {}

  async sendMessage(
    session: ChatSession,
    content: string,
    context: MessageRuntimeContext,
    handlers: RuntimeEventHandlers
  ): Promise<void> {
    await this.ensureStarted();
    this.sessionHandlers.set(session.id, handlers);
    handlers.onStateChange("running");

    const binding = await this.ensureThreadBinding(session, context);
    if (!binding.threadId) {
      throw new Error("Failed to create or resolve app-server thread.");
    }
    binding.expectedCollaborationMode = context.collaborationMode;

    const waiterPromise = new Promise<void>((resolve, reject) => {
      this.sessionTurnWaiters.set(session.id, {
        turnId: "",
        resolve,
        reject
      });
    });

    try {
      const executionPolicy = mapProfileToExecutionPolicy(
        context.profile.id,
        context.requestPermission
      );
      const turnExecutionOverride = mapExecutionPolicyToTurnOverride(executionPolicy);

      const turnStartResult = await this.sendRpcRequest("turn/start", {
        threadId: binding.threadId,
        approvalPolicy: turnExecutionOverride.approvalPolicy,
        ...(turnExecutionOverride.sandboxPolicy
          ? { sandboxPolicy: turnExecutionOverride.sandboxPolicy }
          : {}),
        input: [
          {
            type: "text",
            text: content,
            textElements: []
          }
        ],
        collaborationMode: makeCollaborationModePayload(
          context.collaborationMode,
          context.modelId,
          context.reasoningEffort,
          context.collaborationMode === "plan" && binding.planFallbackActive === true
        )
      });

      const turnId = this.extractTurnId(turnStartResult);
      if (!turnId) {
        throw new Error("turn/start response did not include turn id.");
      }

      binding.activeTurnId = turnId;

      if (
        context.collaborationMode === "plan" &&
        binding.planFallbackActive !== true &&
        binding.nativePlanProbeCompleted !== true
      ) {
        binding.activePlanProbe = {
          turnId,
          sawProposedPlanTag: false,
          requestedUserInput: false,
          askedClarifyingQuestion: false
        };
      } else {
        binding.activePlanProbe = undefined;
      }

      const waiter = this.sessionTurnWaiters.get(session.id);
      if (waiter) {
        waiter.turnId = turnId;
      }

      await waiterPromise;
    } catch (error) {
      this.sessionTurnWaiters.delete(session.id);
      throw error;
    }
  }

  async interrupt(sessionId: string): Promise<void> {
    await this.ensureStarted();

    const binding = this.sessionBindings.get(sessionId);
    if (!binding?.threadId || !binding.activeTurnId) {
      return;
    }

    try {
      await this.sendRpcRequest("turn/interrupt", {
        threadId: binding.threadId,
        turnId: binding.activeTurnId
      });
    } catch (error) {
      this.emitErrorToSession(sessionId, "interrupt_failed", safeString(error));
    }
  }

  async resolvePermission(
    sessionId: string,
    requestId: string,
    approved: boolean
  ): Promise<void> {
    const approval = this.pendingApprovals.get(requestId);
    if (!approval || approval.sessionId !== sessionId) {
      return;
    }

    const decision = approved ? "accept" : "decline";

    this.sendRpcResult(approval.rpcRequestId, {
      decision
    });

    this.pendingApprovals.delete(requestId);

    if (approved) {
      this.sessionHandlers.get(sessionId)?.onStateChange("running");
    }
  }

  async listModels(): Promise<Model[]> {
    await this.ensureStarted();

    const models: Model[] = [];
    let cursor: string | undefined;
    for (let index = 0; index < 20; index += 1) {
      const result = await this.sendRpcRequest("model/list", {
        includeHidden: false,
        ...(cursor ? { cursor } : {})
      });

      const page = this.parseModelListResult(result);
      models.push(...page.data);

      if (!page.nextCursor) {
        break;
      }

      cursor = page.nextCursor;
    }

    return models.length > 0 ? models : DEFAULT_RUNTIME_MODELS;
  }

  async listThreads(params: {
    cwd?: string;
    cursor?: string;
    limit?: number;
  }): Promise<RuntimeThreadListResult> {
    await this.ensureStarted();

    const result = await this.sendRpcRequest("thread/list", {
      cursor: params.cursor ?? null,
      limit: params.limit ?? 20,
      sortKey: "updated_at",
      ...(params.cwd ? { cwd: params.cwd } : {})
    });

    return this.parseThreadListResult(result);
  }

  async resumeThread(threadId: string): Promise<void> {
    await this.ensureStarted();
    await this.sendRpcRequest("thread/resume", {
      threadId
    });
  }

  async readThreadMessages(threadId: string): Promise<RuntimeThreadMessage[]> {
    await this.ensureStarted();
    const result = await this.sendRpcRequest("thread/read", {
      threadId,
      includeTurns: true
    });

    return this.parseThreadReadResult(result);
  }

  async respondUserInput(
    sessionId: string,
    requestId: string,
    answers: Record<string, { answers: string[] }>
  ): Promise<void> {
    const pending = this.pendingUserInputs.get(requestId);
    if (!pending || pending.sessionId !== sessionId) {
      return;
    }

    this.sendRpcResult(pending.rpcRequestId, {
      answers
    });

    this.pendingUserInputs.delete(requestId);
    this.sessionHandlers.get(sessionId)?.onStateChange("running");
  }

  async healthCheck(): Promise<RuntimeHealth> {
    const checks: RuntimeHealth["checks"] = [];
    this.lastCheckedAt = new Date().toISOString();

    const commandCheck = spawnSync(this.command, ["--version"], {
      encoding: "utf-8"
    });

    const commandOk = commandCheck.status === 0;
    const versionText =
      commandCheck.status === 0
        ? commandCheck.stdout.trim() || commandCheck.stderr.trim() || "unknown"
        : null;

    this.version = versionText;

    checks.push({
      name: "command",
      ok: commandOk,
      message: commandOk
        ? `Executable found (${this.command}).`
        : (commandCheck.error?.message ??
            (commandCheck.stderr.trim() || "Unable to execute codex command."))
    });

    let startupOk = false;
    if (commandOk) {
      try {
        await this.ensureStarted();
        startupOk = true;
      } catch (error) {
        this.lastError = safeString(error);
      }
    }

    checks.push({
      name: "connection",
      ok: startupOk,
      message: startupOk
        ? "App-server process initialized."
        : this.lastError ?? "App-server handshake failed."
    });

    let rpcOk = false;
    if (startupOk) {
      try {
        await this.sendRpcRequest("thread/loaded/list", {});
        rpcOk = true;
      } catch (error) {
        this.lastError = safeString(error);
      }
    }

    checks.push({
      name: "rpc",
      ok: rpcOk,
      message: rpcOk
        ? "RPC request succeeded (thread/loaded/list)."
        : this.lastError ?? "RPC probe failed."
    });

    const ready = checks.every((check) => check.ok);

    return {
      ready,
      mode: "app-server",
      transport: "stdio",
      command: this.command,
      args: this.baseArgs,
      version: this.version,
      lastCheckedAt: this.lastCheckedAt,
      checks,
      error: ready
        ? null
        : (this.lastError ?? (this.lastStderr || "Runtime is not ready."))
    };
  }

  async shutdown(): Promise<void> {
    this.ready = false;

    for (const [requestId, pending] of this.pendingRequests) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("Runtime is shutting down."));
      this.pendingRequests.delete(requestId);
    }

    if (this.stdoutReader) {
      this.stdoutReader.close();
      this.stdoutReader = null;
    }

    if (this.process) {
      this.process.kill("SIGTERM");
      this.process = null;
    }

    this.sessionTurnWaiters.clear();
    this.pendingApprovals.clear();
    this.pendingUserInputs.clear();
  }

  private async ensureStarted(): Promise<void> {
    if (this.ready && this.process && this.process.exitCode === null) {
      return;
    }

    if (this.startPromise) {
      await this.startPromise;
      return;
    }

    this.startPromise = this.start();

    try {
      await this.startPromise;
    } finally {
      this.startPromise = null;
    }
  }

  private async start(): Promise<void> {
    this.lastError = null;
    this.lastStderr = "";

    const proc = spawn(this.command, this.baseArgs, {
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"]
    });

    this.process = proc;

    proc.stderr.setEncoding("utf-8");
    proc.stderr.on("data", (chunk: string) => {
      const next = `${this.lastStderr}${chunk}`;
      this.lastStderr = next.slice(-4096);
    });

    proc.on("error", (error) => {
      this.lastError = safeString(error);
      this.ready = false;
    });

    proc.on("close", (code, signal) => {
      this.ready = false;
      this.process = null;
      this.lastError = `Codex app-server exited (code=${code ?? "null"}, signal=${signal ?? "null"}).`;

      for (const [requestId, pending] of this.pendingRequests) {
        clearTimeout(pending.timeout);
        pending.reject(new Error(this.lastError));
        this.pendingRequests.delete(requestId);
      }

      for (const [sessionId, waiter] of this.sessionTurnWaiters) {
        waiter.reject(new Error(this.lastError));
        this.sessionTurnWaiters.delete(sessionId);
      }

      this.pendingApprovals.clear();
      this.pendingUserInputs.clear();
    });

    this.stdoutReader = createInterface({
      input: proc.stdout,
      crlfDelay: Infinity
    });

    this.stdoutReader.on("line", (line: string) => {
      this.handleIncomingLine(line);
    });

    await this.sendRpcRequest("initialize", {
      clientInfo: {
        name: "codex_web_backend",
        title: "Codex Web Backend",
        version: "0.1.0"
      },
      capabilities: {
        experimentalApi: true
      }
    });

    this.sendRpcNotification("initialized");
    this.ready = true;
  }

  private async ensureThreadBinding(
    session: ChatSession,
    context: MessageRuntimeContext
  ): Promise<SessionBinding> {
    const existing = this.sessionBindings.get(session.id) ?? {
      threadId: session.threadId ?? undefined,
      threadLoaded: false
    };
    this.sessionBindings.set(session.id, existing);

    if (existing.threadId) {
      this.threadToSession.set(existing.threadId, session.id);
      if (!existing.threadLoaded) {
        await this.sendRpcRequest("thread/resume", {
          threadId: existing.threadId
        });
        existing.threadLoaded = true;
      }
      return existing;
    }

    const executionPolicy = mapProfileToExecutionPolicy(
      context.profile.id,
      context.requestPermission
    );

    const threadStartResult = await this.sendRpcRequest("thread/start", {
      model: context.modelId,
      cwd: context.project.path,
      approvalPolicy: executionPolicy.approvalPolicy,
      sandbox: executionPolicy.sandbox
    });

    const threadId = this.extractThreadId(threadStartResult);
    if (!threadId) {
      throw new Error("thread/start response did not include thread id.");
    }

    existing.threadId = threadId;
    existing.threadLoaded = true;
    this.threadToSession.set(threadId, session.id);

    return existing;
  }

  private extractThreadId(value: unknown): string | null {
    if (!hasRecordShape(value)) {
      return null;
    }

    const thread = value.thread;
    if (!hasRecordShape(thread) || typeof thread.id !== "string") {
      return null;
    }

    return thread.id;
  }

  private extractTurnId(value: unknown): string | null {
    if (!hasRecordShape(value)) {
      return null;
    }

    const turn = value.turn;
    if (!hasRecordShape(turn) || typeof turn.id !== "string") {
      return null;
    }

    return turn.id;
  }

  private parseModelListResult(value: unknown): {
    data: Model[];
    nextCursor: string | null;
  } {
    if (!hasRecordShape(value)) {
      return { data: [], nextCursor: null };
    }

    const rawModels = Array.isArray(value.data) ? value.data : [];
    const data: Model[] = rawModels
      .filter((item): item is Record<string, unknown> => hasRecordShape(item))
      .map((item) => {
        const supportedReasoningEfforts = Array.isArray(item.supportedReasoningEfforts)
          ? item.supportedReasoningEfforts
              .filter((entry): entry is Record<string, unknown> => hasRecordShape(entry))
              .map((entry) => safeString(entry.reasoningEffort))
              .filter(
                (entry): entry is "low" | "medium" | "high" | "xhigh" =>
                  entry === "low" ||
                  entry === "medium" ||
                  entry === "high" ||
                  entry === "xhigh"
              )
          : [];

        const defaultReasoningEffort = safeString(item.defaultReasoningEffort);
        const normalizedDefault =
          defaultReasoningEffort === "low" ||
          defaultReasoningEffort === "medium" ||
          defaultReasoningEffort === "high" ||
          defaultReasoningEffort === "xhigh"
            ? defaultReasoningEffort
            : "medium";

        return {
          id: safeString(item.id),
          displayName: safeString(item.displayName) || safeString(item.model),
          capabilities: ["tool-use", "code", "reasoning"],
          defaultProfileIds: ["xhigh", "yolo"],
          supportedReasoningEfforts:
            supportedReasoningEfforts.length > 0
              ? supportedReasoningEfforts
              : ["low", "medium", "high", "xhigh"],
          defaultReasoningEffort: normalizedDefault
        } satisfies Model;
      })
      .filter((model) => model.id.length > 0);

    const nextCursor =
      typeof value.nextCursor === "string" && value.nextCursor.length > 0
        ? value.nextCursor
        : null;

    return {
      data,
      nextCursor
    };
  }

  private parseThreadListResult(value: unknown): RuntimeThreadListResult {
    if (!hasRecordShape(value)) {
      return { data: [], nextCursor: null };
    }

    const threads = Array.isArray(value.data) ? value.data : [];
    const data = threads
      .filter((item): item is Record<string, unknown> => hasRecordShape(item))
      .map((item) => {
        const createdAtSeconds = Number(item.createdAt);
        const updatedAtSeconds = Number(item.updatedAt);

        const createdAt = Number.isFinite(createdAtSeconds)
          ? new Date(createdAtSeconds * 1000).toISOString()
          : new Date().toISOString();
        const updatedAt = Number.isFinite(updatedAtSeconds)
          ? new Date(updatedAtSeconds * 1000).toISOString()
          : createdAt;

        const statusValue = hasRecordShape(item.status)
          ? safeString(item.status.type)
          : safeString(item.status);

        return {
          threadId: safeString(item.id),
          preview: safeString(item.preview),
          cwd: safeString(item.cwd) || null,
          createdAt,
          updatedAt,
          status: statusValue || "unknown"
        } satisfies RuntimeThreadHistoryItem;
      })
      .filter((thread) => thread.threadId.length > 0);

    const nextCursor =
      typeof value.nextCursor === "string" && value.nextCursor.length > 0
        ? value.nextCursor
        : null;

    return {
      data,
      nextCursor
    };
  }

  private parseThreadReadResult(value: unknown): RuntimeThreadMessage[] {
    if (!hasRecordShape(value)) {
      return [];
    }

    const thread = hasRecordShape(value.thread) ? value.thread : null;
    if (!thread) {
      return [];
    }

    const turns = Array.isArray(thread.turns) ? thread.turns : [];
    const messages: RuntimeThreadMessage[] = [];

    for (const turn of turns) {
      if (!hasRecordShape(turn)) {
        continue;
      }

      const items = Array.isArray(turn.items) ? turn.items : [];
      for (const item of items) {
        if (!hasRecordShape(item)) {
          continue;
        }

        const type = safeString(item.type);

        if (type === "userMessage") {
          const content = this.extractUserMessageText(item.content);
          if (content.length > 0) {
            messages.push({
              role: "user",
              content
            });
          }
          continue;
        }

        if (type === "agentMessage") {
          const text = safeString(item.text).trim();
          if (text.length > 0) {
            messages.push({
              role: "assistant",
              content: text
            });
          }
          continue;
        }

        if (type === "plan") {
          const text = safeString(item.text).trim();
          if (text.length > 0) {
            messages.push({
              role: "assistant",
              content: text
            });
          }
        }
      }
    }

    return messages;
  }

  private extractUserMessageText(value: unknown): string {
    if (!Array.isArray(value)) {
      return safeString(value).trim();
    }

    const parts: string[] = [];

    for (const entry of value) {
      if (!hasRecordShape(entry)) {
        continue;
      }

      const type = safeString(entry.type);

      if (type === "text") {
        const text = safeString(entry.text).trim();
        if (text.length > 0) {
          parts.push(text);
        }
        continue;
      }

      if (type === "image") {
        const url = safeString(entry.url).trim();
        parts.push(url.length > 0 ? `[image] ${url}` : "[image]");
        continue;
      }

      if (type === "localImage") {
        const pathValue = safeString(entry.path).trim();
        parts.push(pathValue.length > 0 ? `[local-image] ${pathValue}` : "[local-image]");
      }
    }

    return parts.join("\n").trim();
  }

  private async sendRpcRequest(
    method: string,
    params: Record<string, unknown>
  ): Promise<unknown> {
    await this.waitForWritableProcess();

    const requestId = this.nextRpcId;
    this.nextRpcId += 1;

    return new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(requestId);
        reject(new Error(`Timed out waiting for app-server response: ${method}`));
      }, 60_000);

      this.pendingRequests.set(requestId, {
        method,
        resolve,
        reject,
        timeout
      });

      this.writeJsonLine({
        id: requestId,
        method,
        params
      });
    });
  }

  private sendRpcNotification(
    method: string,
    params?: Record<string, unknown>
  ): void {
    this.writeJsonLine({
      method,
      ...(params ? { params } : {})
    });
  }

  private sendRpcResult(id: string | number, result: Record<string, unknown>): void {
    this.writeJsonLine({
      id,
      result
    });
  }

  private async waitForWritableProcess(): Promise<void> {
    if (!this.process || this.process.exitCode !== null) {
      throw new Error(this.lastError ?? "Codex app-server process is unavailable.");
    }

    if (this.process.stdin.destroyed) {
      throw new Error("Codex app-server stdin is closed.");
    }
  }

  private writeJsonLine(payload: Record<string, unknown>): void {
    const proc = this.process;
    if (!proc || proc.exitCode !== null || proc.stdin.destroyed) {
      throw new Error(this.lastError ?? "Cannot write to codex app-server process.");
    }

    proc.stdin.write(`${JSON.stringify(payload)}\n`);
  }

  private handleIncomingLine(line: string): void {
    const trimmed = line.trim();
    if (!trimmed) {
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      return;
    }

    if (!hasRecordShape(parsed)) {
      return;
    }

    const hasMethod = typeof parsed.method === "string";
    const hasId = typeof parsed.id === "number" || typeof parsed.id === "string";

    if (hasMethod && hasId) {
      this.handleServerRequest(parsed);
      return;
    }

    if (hasMethod && !hasId) {
      this.handleServerNotification(parsed);
      return;
    }

    if (hasId && "result" in parsed) {
      this.handleRpcResult(parsed);
      return;
    }

    if (hasId && "error" in parsed) {
      this.handleRpcError(parsed);
    }
  }

  private handleRpcResult(message: Record<string, unknown>): void {
    const requestId = message.id;
    if (typeof requestId !== "number") {
      return;
    }

    const pending = this.pendingRequests.get(requestId);
    if (!pending) {
      return;
    }

    clearTimeout(pending.timeout);
    this.pendingRequests.delete(requestId);
    pending.resolve(message.result);
  }

  private handleRpcError(message: Record<string, unknown>): void {
    const requestId = message.id;
    if (typeof requestId !== "number") {
      return;
    }

    const pending = this.pendingRequests.get(requestId);
    if (!pending) {
      return;
    }

    clearTimeout(pending.timeout);
    this.pendingRequests.delete(requestId);

    let errorMessage = "Unknown JSON-RPC error";
    if (hasRecordShape(message.error) && typeof message.error.message === "string") {
      errorMessage = message.error.message;
    }

    pending.reject(new Error(`${pending.method}: ${errorMessage}`));
  }

  private handleServerRequest(message: Record<string, unknown>): void {
    const method = message.method;
    const rpcRequestId = message.id;

    if (typeof method !== "string") {
      return;
    }

    if (!(typeof rpcRequestId === "string" || typeof rpcRequestId === "number")) {
      return;
    }

    const params = hasRecordShape(message.params) ? message.params : {};

    if (method === "item/commandExecution/requestApproval") {
      this.handleCommandApprovalRequest(rpcRequestId, params);
      return;
    }

    if (method === "item/fileChange/requestApproval") {
      this.handleFileApprovalRequest(rpcRequestId, params);
      return;
    }

    if (method === "item/tool/requestUserInput") {
      this.handleUserInputRequest(rpcRequestId, params);
      return;
    }

    if (method === "item/tool/call") {
      this.sendRpcResult(rpcRequestId, {
        success: false,
        contentItems: []
      });
      return;
    }

    this.sendRpcResult(rpcRequestId, {});
  }

  private handleCommandApprovalRequest(
    rpcRequestId: string | number,
    params: Record<string, unknown>
  ): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      this.sendRpcResult(rpcRequestId, { decision: "decline" });
      return;
    }

    const localRequestId = randomUUID();
    this.pendingApprovals.set(localRequestId, {
      sessionId,
      rpcRequestId,
      kind: "command"
    });

    const command = safeString(params.command);
    const reason = safeString(params.reason);
    const prompt = reason || command || "Approve command execution?";

    const handlers = this.sessionHandlers.get(sessionId);
    handlers?.onStateChange("awaiting_permission");
    handlers?.onPermissionRequested(localRequestId, prompt);
  }

  private handleFileApprovalRequest(
    rpcRequestId: string | number,
    params: Record<string, unknown>
  ): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      this.sendRpcResult(rpcRequestId, { decision: "decline" });
      return;
    }

    const localRequestId = randomUUID();
    this.pendingApprovals.set(localRequestId, {
      sessionId,
      rpcRequestId,
      kind: "file"
    });

    const reason = safeString(params.reason);
    const prompt = reason || "Approve file changes?";

    const handlers = this.sessionHandlers.get(sessionId);
    handlers?.onStateChange("awaiting_permission");
    handlers?.onPermissionRequested(localRequestId, prompt);
  }

  private handleUserInputRequest(
    rpcRequestId: string | number,
    params: Record<string, unknown>
  ): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      this.sendRpcResult(rpcRequestId, { answers: {} });
      return;
    }

    const questionsValue = Array.isArray(params.questions) ? params.questions : [];
    const questions: UserInputQuestion[] = questionsValue
      .filter((question): question is Record<string, unknown> => hasRecordShape(question))
      .map((question) => {
        const optionsValue = Array.isArray(question.options) ? question.options : [];
        const options = optionsValue
          .filter((option): option is Record<string, unknown> => hasRecordShape(option))
          .map((option) => ({
            label: safeString(option.label),
            description: safeString(option.description)
          }))
          .filter((option) => option.label.length > 0);

        return {
          header: safeString(question.header),
          id: safeString(question.id),
          question: safeString(question.question),
          options
        };
      })
      .filter((question) => question.id.length > 0);

    if (questions.length === 0) {
      this.sendRpcResult(rpcRequestId, { answers: {} });
      return;
    }

    const localRequestId = randomUUID();
    this.pendingUserInputs.set(localRequestId, {
      sessionId,
      rpcRequestId
    });

    const handlers = this.sessionHandlers.get(sessionId);
    const binding = this.sessionBindings.get(sessionId);
    if (binding?.activePlanProbe) {
      binding.activePlanProbe.requestedUserInput = true;
    }
    handlers?.onStateChange("awaiting_permission");
    handlers?.onUserInputRequested(localRequestId, questions);
  }

  private handleServerNotification(message: Record<string, unknown>): void {
    const method = message.method;
    if (typeof method !== "string") {
      return;
    }

    const params = hasRecordShape(message.params) ? message.params : {};

    if (method === "turn/started") {
      const threadId = safeString(params.threadId);
      const turn = hasRecordShape(params.turn) ? params.turn : null;
      const turnId = turn && typeof turn.id === "string" ? turn.id : undefined;
      const sessionId = this.threadToSession.get(threadId);
      if (!sessionId || !turnId) {
        return;
      }

      const binding = this.sessionBindings.get(sessionId);
      if (binding) {
        binding.activeTurnId = turnId;
        const reportedMode = parseModeKind(
          params.collaborationModeKind ??
            params.collaboration_mode_kind ??
            (turn ? turn.collaborationModeKind : null) ??
            (turn ? turn.collaboration_mode_kind : null)
        );
        if (
          binding.expectedCollaborationMode === "plan" &&
          reportedMode === "default"
        ) {
          this.enablePlanModeFallback(
            sessionId,
            "Runtime reported Default mode during a Plan-mode turn."
          );
        }
      }

      this.sessionHandlers.get(sessionId)?.onStateChange("running");
      return;
    }

    if (method === "item/started") {
      this.handleItemStarted(params);
      return;
    }

    if (method === "item/agentMessage/delta") {
      this.handleAgentMessageDelta(params);
      return;
    }

    if (method === "item/plan/delta") {
      this.handlePlanDelta(params);
      return;
    }

    if (method === "item/completed") {
      this.handleItemCompleted(params);
      return;
    }

    if (method === "turn/diff/updated") {
      this.handleTurnDiffUpdated(params);
      return;
    }

    if (method === "turn/completed") {
      this.handleTurnCompleted(params);
      return;
    }

    if (method === "error") {
      this.handleErrorNotification(params);
    }
  }

  private handleItemStarted(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      return;
    }

    const item = hasRecordShape(params.item) ? params.item : null;
    if (!item || typeof item.type !== "string") {
      return;
    }

    const handlers = this.sessionHandlers.get(sessionId);
    if (!handlers) {
      return;
    }

    if (item.type === "agentMessage" && typeof item.id === "string") {
      const binding = this.sessionBindings.get(sessionId);
      if (binding) {
        binding.activeAssistantItemId = item.id;
      }
      return;
    }

    if (item.type === "commandExecution") {
      handlers.onToolStarted("command_execution", safeString(item.command));
      return;
    }

    if (item.type === "mcpToolCall") {
      const server = safeString(item.server);
      const tool = safeString(item.tool);
      handlers.onToolStarted(`${server}.${tool}`, safeString(item.arguments));
      return;
    }

    if (item.type === "dynamicToolCall") {
      handlers.onToolStarted(safeString(item.tool), safeString(item.arguments));
      return;
    }

    if (item.type === "webSearch") {
      handlers.onToolStarted("web_search", safeString(item.query));
      return;
    }

    if (item.type === "fileChange") {
      handlers.onToolStarted("file_change", "Applying workspace changes");
    }
  }

  private handleAgentMessageDelta(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      return;
    }

    const itemId = safeString(params.itemId);
    const delta = safeString(params.delta);
    if (!itemId || !delta) {
      return;
    }

    const binding = this.sessionBindings.get(sessionId);
    if (binding) {
      binding.activeAssistantItemId = itemId;
    }

    this.sessionHandlers.get(sessionId)?.onDelta(itemId, delta);
  }

  private handlePlanDelta(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      return;
    }

    const itemId = safeString(params.itemId);
    const delta = safeString(params.delta);
    if (!itemId || !delta) {
      return;
    }

    this.sessionHandlers.get(sessionId)?.onDelta(itemId, delta);
  }

  private handleItemCompleted(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      return;
    }

    const item = hasRecordShape(params.item) ? params.item : null;
    if (!item || typeof item.type !== "string") {
      return;
    }

    const handlers = this.sessionHandlers.get(sessionId);
    if (!handlers) {
      return;
    }

    if (item.type === "agentMessage") {
      const messageId = safeString(item.id) || randomUUID();
      const text = safeString(item.text);
      this.recordPlanProbeMessage(sessionId, text);
      handlers.onCompleted(messageId, text);
      return;
    }

    if (item.type === "plan") {
      const messageId = safeString(item.id) || randomUUID();
      const text = safeString(item.text);
      this.recordPlanProbeMessage(sessionId, text);
      handlers.onCompleted(messageId, text);
      return;
    }

    if (item.type === "commandExecution") {
      const status = safeString(item.status);
      const ok = status === "completed";
      const output = safeString(item.aggregatedOutput) || safeString(item.exitCode);
      handlers.onToolCompleted("command_execution", ok, output || status);
      return;
    }

    if (item.type === "mcpToolCall") {
      const status = safeString(item.status);
      const ok = status === "completed";
      const toolName = `${safeString(item.server)}.${safeString(item.tool)}`;
      const output = safeString(item.result) || safeString(item.error) || status;
      handlers.onToolCompleted(toolName, ok, output);
      return;
    }

    if (item.type === "dynamicToolCall") {
      const status = safeString(item.status);
      const ok = status === "completed";
      const output = safeString(item.contentItems) || safeString(item.success) || status;
      handlers.onToolCompleted(safeString(item.tool), ok, output);
      return;
    }

    if (item.type === "webSearch") {
      handlers.onToolCompleted("web_search", true, safeString(item.query));
      return;
    }

    if (item.type === "fileChange") {
      const status = safeString(item.status);
      const ok = status === "completed";
      const changes = Array.isArray(item.changes) ? item.changes.length : 0;
      handlers.onToolCompleted("file_change", ok, `${changes} file(s)`);
    }
  }

  private handleTurnCompleted(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      return;
    }

    const turn = hasRecordShape(params.turn) ? params.turn : null;
    const turnId = turn ? safeString(turn.id) : "";
    const status = turn ? safeString(turn.status) : "";

    this.finalizePlanProbe(sessionId, turnId, status);

    const binding = this.sessionBindings.get(sessionId);
    if (binding) {
      binding.activeTurnId = undefined;
    }

    const handlers = this.sessionHandlers.get(sessionId);
    if (!handlers) {
      return;
    }

    const waiter = this.sessionTurnWaiters.get(sessionId);
    if (waiter && waiter.turnId && turnId && waiter.turnId != turnId) {
      return;
    }

    if (status === "completed") {
      handlers.onStateChange("completed");
      if (waiter) {
        waiter.resolve();
        this.sessionTurnWaiters.delete(sessionId);
      }
      return;
    }

    if (status === "interrupted") {
      handlers.onStateChange("cancelled");
      if (waiter) {
        waiter.reject(new Error("Turn interrupted."));
        this.sessionTurnWaiters.delete(sessionId);
      }
      return;
    }

    const turnError =
      turn && hasRecordShape(turn.error)
        ? safeString(turn.error.message)
        : "Turn failed.";

    handlers.onStateChange("failed");
    handlers.onError("turn_failed", turnError);

    if (waiter) {
      waiter.reject(new Error(turnError));
      this.sessionTurnWaiters.delete(sessionId);
    }
  }

  private handleTurnDiffUpdated(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    if (!sessionId) {
      return;
    }

    const turnId = safeString(params.turnId);
    const diff = safeString(params.diff);
    if (!turnId || !diff) {
      return;
    }

    this.sessionHandlers.get(sessionId)?.onTurnDiff(turnId, diff);
  }

  private handleErrorNotification(params: Record<string, unknown>): void {
    const threadId = safeString(params.threadId);
    const sessionId = this.threadToSession.get(threadId);
    const error = hasRecordShape(params.error) ? params.error : null;
    const message = error ? safeString(error.message) : safeString(params.message);

    if (!sessionId) {
      this.lastError = message || "Unknown runtime error";
      return;
    }

    if (containsPlanModeFallbackSignal(message)) {
      this.enablePlanModeFallback(
        sessionId,
        "Runtime indicated Plan-mode tools are unavailable in Default mode."
      );
    }

    this.emitErrorToSession(sessionId, "codex_error", message || "Unknown runtime error");
  }

  private recordPlanProbeMessage(sessionId: string, content: string): void {
    const binding = this.sessionBindings.get(sessionId);
    const probe = binding?.activePlanProbe;
    if (!probe) {
      return;
    }

    if (content.includes("<proposed_plan>") && content.includes("</proposed_plan>")) {
      probe.sawProposedPlanTag = true;
    }

    if (endsWithQuestion(content)) {
      probe.askedClarifyingQuestion = true;
    }
  }

  private finalizePlanProbe(
    sessionId: string,
    completedTurnId: string,
    status: string
  ): void {
    const binding = this.sessionBindings.get(sessionId);
    const probe = binding?.activePlanProbe;
    if (!binding || !probe) {
      return;
    }

    if (completedTurnId && probe.turnId && completedTurnId !== probe.turnId) {
      return;
    }

    binding.activePlanProbe = undefined;
    binding.nativePlanProbeCompleted = true;

    if (status !== "completed") {
      return;
    }

    const nativePlanLooksHealthy =
      probe.sawProposedPlanTag || probe.requestedUserInput || probe.askedClarifyingQuestion;

    if (!nativePlanLooksHealthy) {
      this.enablePlanModeFallback(
        sessionId,
        "Native Plan mode output did not match codex-cli planning behavior."
      );
    }
  }

  private enablePlanModeFallback(sessionId: string, reason: string): void {
    const binding = this.sessionBindings.get(sessionId);
    if (!binding || binding.planFallbackActive === true) {
      return;
    }

    if (binding.expectedCollaborationMode !== "plan") {
      return;
    }

    binding.planFallbackActive = true;

    const handlers = this.sessionHandlers.get(sessionId);
    handlers?.onToolStarted("plan_mode_fallback", reason);
    handlers?.onToolCompleted(
      "plan_mode_fallback",
      true,
      "Future Plan-mode turns will use codex-cli compatible instructions."
    );
  }

  private emitErrorToSession(sessionId: string, code: string, message: string): void {
    const handlers = this.sessionHandlers.get(sessionId);
    if (!handlers) {
      return;
    }

    handlers.onError(code, message);
  }
}

export const createRuntime = (options: {
  mode: "mock" | "app-server" | "cli";
  command: string;
  args: string[];
}): CodexRuntime => {
  if (options.mode === "mock") {
    return new MockCodexRuntime();
  }

  return new AppServerCodexRuntime(options.command, options.args);
};
