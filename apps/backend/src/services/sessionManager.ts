import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import type {
  ChatMessage,
  ChatSession,
  CollaborationMode,
  Model,
  PermissionProfile,
  Project,
  ReasoningEffort,
  ServerEvent,
  SessionActionRequest
} from "@codex/contracts";
import { InMemoryStore } from "../store/inMemoryStore.js";
import {
  type CodexRuntime,
  type MessageRuntimeContext,
  type RuntimeThreadMessage,
  type RuntimeThreadListResult,
  type UserInputQuestion
} from "../adapters/codexRuntime.js";
import { NotificationService } from "./notificationService.js";

type Catalogs = {
  models: Model[];
  profiles: PermissionProfile[];
};

type ProjectGetter = () => Project[];

export class SessionManager {
  private readonly eventBus = new EventEmitter();
  private readonly assistantDrafts = new Map<string, string>();
  private readonly pendingPermissionRequests = new Map<string, string>();
  private readonly pendingUserInputRequests = new Map<string, string>();

  constructor(
    private readonly store: InMemoryStore,
    private readonly catalogs: Catalogs,
    private readonly getProjects: ProjectGetter,
    private readonly runtime: CodexRuntime,
    private readonly notificationService: NotificationService
  ) {}

  onServerEvent(handler: (event: ServerEvent) => void): () => void {
    this.eventBus.on("server-event", handler);
    return () => this.eventBus.off("server-event", handler);
  }

  createSession(input: {
    projectId: string;
    modelId: string;
    profileId: string;
    reasoningEffort: ReasoningEffort;
    collaborationMode: CollaborationMode;
    threadId?: string | null;
  }): ChatSession {
    const project = this.getProject(input.projectId);
    if (!project) {
      throw new Error("Project not found");
    }

    const model = this.getModel(input.modelId);
    if (!model) {
      throw new Error("Model not found");
    }

    const profile = this.getProfile(input.profileId);
    if (!profile) {
      throw new Error("Permission profile not found");
    }

    const session: ChatSession = {
      id: randomUUID(),
      projectId: project.id,
      modelId: model.id,
      profileId: profile.id,
      collaborationMode: input.collaborationMode,
      reasoningEffort: input.reasoningEffort,
      threadId: input.threadId ?? null,
      status: "idle",
      startedAt: new Date().toISOString(),
      endedAt: null
    };

    this.store.addSession(session);
    void this.emitEvent({ type: "session.started", payload: session });
    return session;
  }

  getSession(sessionId: string): ChatSession | undefined {
    return this.store.getSession(sessionId);
  }

  getMessages(sessionId: string): ChatMessage[] {
    return this.store.getMessages(sessionId);
  }

  async listHistory(params: {
    cwd?: string;
    cursor?: string;
    limit?: number;
  }): Promise<RuntimeThreadListResult> {
    return this.runtime.listThreads(params);
  }

  async resumeSession(input: {
    threadId: string;
    projectId: string;
    modelId: string;
    profileId: string;
    reasoningEffort: ReasoningEffort;
    collaborationMode: CollaborationMode;
  }): Promise<{ session: ChatSession; messages: ChatMessage[] }> {
    const existing = this.store
      .listSessions()
      .find((session) => session.threadId === input.threadId);
    if (existing) {
      if (this.store.getMessages(existing.id).length > 0) {
        return {
          session: existing,
          messages: this.store.getMessages(existing.id)
        };
      }

      const hydrated = await this.hydrateThreadHistory(existing.id, input.threadId);
      return {
        session: existing,
        messages: hydrated
      };
    }

    await this.runtime.resumeThread(input.threadId);

    const session = this.createSession({
      projectId: input.projectId,
      modelId: input.modelId,
      profileId: input.profileId,
      reasoningEffort: input.reasoningEffort,
      collaborationMode: input.collaborationMode,
      threadId: input.threadId
    });
    const messages = await this.hydrateThreadHistory(session.id, input.threadId);

    return {
      session,
      messages
    };
  }

  async sendMessage(
    sessionId: string,
    content: string,
    requestPermission: boolean
  ): Promise<ChatMessage> {
    const session = this.store.getSession(sessionId);
    if (!session) {
      throw new Error("Session not found");
    }

    const userMessage: ChatMessage = {
      id: randomUUID(),
      sessionId,
      role: "user",
      content,
      createdAt: new Date().toISOString()
    };

    this.store.addMessage(userMessage);
    void this.emitEvent({ type: "message.completed", payload: userMessage });

    const runtimeContext = this.buildRuntimeContext(session, requestPermission);

    void this.runtime.sendMessage(session, content, runtimeContext, {
      onToolStarted: (toolName, inputSummary) => {
        void this.emitEvent({
          type: "tool.started",
          payload: {
            sessionId,
            toolName,
            inputSummary
          }
        });
      },
      onToolCompleted: (toolName, success, outputSummary) => {
        void this.emitEvent({
          type: "tool.completed",
          payload: {
            sessionId,
            toolName,
            success,
            outputSummary
          }
        });
      },
      onTurnDiff: (turnId, diff) => {
        void this.emitEvent(
          {
            type: "turn.diff.updated",
            payload: {
              sessionId,
              turnId,
              diff
            }
          },
          false
        );
      },
      onPermissionRequested: (requestId, prompt) => {
        this.pendingPermissionRequests.set(sessionId, requestId);
        void this.emitEvent({
          type: "permission.requested",
          payload: {
            sessionId,
            requestId,
            prompt
          }
        });
      },
      onDelta: (messageId, delta) => {
        const existing = this.assistantDrafts.get(messageId) ?? "";
        this.assistantDrafts.set(messageId, `${existing}${delta}`);

        void this.emitEvent({
          type: "message.delta",
          payload: {
            sessionId,
            messageId,
            delta
          }
        });
      },
      onCompleted: (messageId, contentValue) => {
        const message: ChatMessage = {
          id: messageId,
          sessionId,
          role: "assistant",
          content: contentValue,
          createdAt: new Date().toISOString()
        };

        this.store.replaceMessage(message);
        this.assistantDrafts.delete(messageId);
        void this.emitEvent({ type: "message.completed", payload: message });
      },
      onUserInputRequested: (requestId, questions) => {
        this.pendingUserInputRequests.set(sessionId, requestId);
        void this.emitEvent({
          type: "user.input.requested",
          payload: {
            sessionId,
            requestId,
            questions: this.normalizeUserInputQuestions(questions)
          }
        });
      },
      onStateChange: (status) => {
        const existingSession = this.store.getSession(sessionId);
        if (!existingSession) {
          return;
        }

        const updated: ChatSession = {
          ...existingSession,
          status,
          endedAt:
            status === "completed" || status === "failed" || status === "cancelled"
              ? new Date().toISOString()
              : null
        };
        this.store.updateSession(updated);
        void this.emitEvent({
          type: "session.state.changed",
          payload: { sessionId, status }
        });
      },
      onError: (code, message) => {
        void this.emitEvent({
          type: "error",
          payload: { code, message, sessionId }
        });
      }
    });

    return userMessage;
  }

  async getRuntimeHealth() {
    return this.runtime.healthCheck();
  }

  async handleAction(
    sessionId: string,
    actionRequest: SessionActionRequest
  ): Promise<void> {
    const session = this.store.getSession(sessionId);
    if (!session) {
      throw new Error("Session not found");
    }

    if (actionRequest.action === "interrupt") {
      await this.runtime.interrupt(sessionId);
      const updated = { ...session, status: "cancelled" as const, endedAt: new Date().toISOString() };
      this.store.updateSession(updated);
      await this.emitEvent({
        type: "session.state.changed",
        payload: {
          sessionId,
          status: "cancelled"
        }
      });
      return;
    }

    if (actionRequest.action === "retry") {
      const messages = this.store.getMessages(sessionId);
      const lastUserMessage = [...messages].reverse().find((message) => message.role === "user");
      if (!lastUserMessage) {
        throw new Error("No user message available for retry");
      }
      await this.sendMessage(sessionId, lastUserMessage.content, false);
      return;
    }

    if (actionRequest.action === "approve" || actionRequest.action === "deny") {
      const pendingPermission =
        actionRequest.requestId ?? this.pendingPermissionRequests.get(sessionId) ?? "";
      if (!pendingPermission) {
        throw new Error("No pending permission request");
      }
      await this.runtime.resolvePermission(
        sessionId,
        pendingPermission,
        actionRequest.action === "approve"
      );
      this.pendingPermissionRequests.delete(sessionId);
      await this.emitEvent({
        type: "permission.resolved",
        payload: {
          sessionId,
          requestId: pendingPermission,
          approved: actionRequest.action === "approve"
        }
      });
    }
  }

  async broadcastProjectUpdate(projects: Project[]): Promise<void> {
    await this.emitEvent({
      type: "project.scan.updated",
      payload: { projects }
    });
  }

  async resolvePermission(
    sessionId: string,
    requestId: string,
    approved: boolean
  ): Promise<void> {
    await this.runtime.resolvePermission(sessionId, requestId, approved);
    this.pendingPermissionRequests.delete(sessionId);
    await this.emitEvent({
      type: "permission.resolved",
      payload: { sessionId, requestId, approved }
    });
  }

  async resolveUserInput(
    sessionId: string,
    requestId: string,
    answers: Record<string, { answers: string[] }>
  ): Promise<void> {
    await this.runtime.respondUserInput(sessionId, requestId, answers);
    this.pendingUserInputRequests.delete(sessionId);
    await this.emitEvent({
      type: "user.input.resolved",
      payload: {
        sessionId,
        requestId
      }
    });
  }

  private buildRuntimeContext(
    session: ChatSession,
    requestPermission: boolean
  ): MessageRuntimeContext {
    const project = this.getProject(session.projectId);
    const profile = this.getProfile(session.profileId);

    if (!project || !profile) {
      throw new Error("Session references invalid project or profile");
    }

    const normalizedRequestPermission =
      profile.id === "yolo" ? false : requestPermission;

    return {
      modelId: session.modelId,
      collaborationMode: session.collaborationMode,
      reasoningEffort: session.reasoningEffort,
      project,
      profile,
      requestPermission: normalizedRequestPermission
    };
  }

  private normalizeUserInputQuestions(questions: UserInputQuestion[]) {
    return questions.map((question) => ({
      header: question.header,
      id: question.id,
      question: question.question,
      options: question.options
    }));
  }

  private getProject(projectId: string): Project | undefined {
    return this.getProjects().find((project) => project.id === projectId);
  }

  private getModel(modelId: string): Model | undefined {
    return this.catalogs.models.find((model) => model.id === modelId);
  }

  private getProfile(profileId: string): PermissionProfile | undefined {
    return this.catalogs.profiles.find((profile) => profile.id === profileId);
  }

  private async hydrateThreadHistory(
    sessionId: string,
    threadId: string
  ): Promise<ChatMessage[]> {
    const existingMessages = this.store.getMessages(sessionId);
    if (existingMessages.length > 0) {
      return existingMessages;
    }

    const runtimeMessages = await this.runtime.readThreadMessages(threadId);
    if (runtimeMessages.length === 0) {
      return [];
    }

    const baseTimestamp = Date.now() - runtimeMessages.length * 10;
    runtimeMessages.forEach((item, index) => {
      const message = this.makeHydratedMessage(
        sessionId,
        threadId,
        item,
        baseTimestamp + index * 10
      );
      this.store.addMessage(message);
    });

    return this.store.getMessages(sessionId);
  }

  private makeHydratedMessage(
    sessionId: string,
    threadId: string,
    message: RuntimeThreadMessage,
    timestampMs: number
  ): ChatMessage {
    return {
      id: `hist-${threadId}-${randomUUID()}`,
      sessionId,
      role: message.role,
      content: message.content,
      createdAt: new Date(timestampMs).toISOString()
    };
  }

  private async emitEvent(event: ServerEvent, sendNotification = true): Promise<void> {
    this.eventBus.emit("server-event", event);

    if (!sendNotification) {
      return;
    }

    const notificationType = this.mapEventToNotification(event.type);
    if (!notificationType) {
      return;
    }

    const notification = await this.notificationService.dispatch(
      notificationType,
      event.payload as Record<string, unknown>,
      this.extractSessionId(event)
    );

    this.eventBus.emit("server-event", {
      type: "notification.dispatched",
      payload: notification
    } satisfies ServerEvent);
  }

  private extractSessionId(event: ServerEvent): string | null {
    if (event.type === "session.started") {
      return event.payload.id;
    }

    if ("sessionId" in event.payload) {
      return (event.payload as { sessionId: string }).sessionId;
    }

    return null;
  }

  private mapEventToNotification(type: ServerEvent["type"]) {
    if (type.startsWith("message.")) {
      return "message" as const;
    }

    if (type.startsWith("tool.")) {
      return "tool" as const;
    }

    if (type.startsWith("permission.")) {
      return "permission" as const;
    }

    if (type.startsWith("user.input.")) {
      return "permission" as const;
    }

    if (type.startsWith("session.")) {
      return "session" as const;
    }

    if (type === "error") {
      return "error" as const;
    }

    return null;
  }
}
