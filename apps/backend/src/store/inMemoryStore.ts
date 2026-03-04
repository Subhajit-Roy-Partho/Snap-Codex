import type {
  ChatMessage,
  ChatSession,
  NotificationEvent,
  NotificationSettings,
  Project
} from "@codex/contracts";

export class InMemoryStore {
  private projects = new Map<string, Project>();
  private sessions = new Map<string, ChatSession>();
  private messages = new Map<string, ChatMessage[]>();
  private pushTokens = new Set<string>();
  private notificationEvents: NotificationEvent[] = [];
  private notificationSettings: NotificationSettings = {
    message: true,
    tool: true,
    permission: true,
    session: true,
    error: true
  };

  upsertProjects(items: Project[]): void {
    items.forEach((project) => this.projects.set(project.id, project));
  }

  getProjects(): Project[] {
    return Array.from(this.projects.values()).sort((a, b) =>
      a.name.localeCompare(b.name)
    );
  }

  addSession(session: ChatSession): void {
    this.sessions.set(session.id, session);
    this.messages.set(session.id, []);
  }

  updateSession(session: ChatSession): void {
    this.sessions.set(session.id, session);
  }

  getSession(id: string): ChatSession | undefined {
    return this.sessions.get(id);
  }

  listSessions(): ChatSession[] {
    return Array.from(this.sessions.values()).sort((a, b) =>
      a.startedAt.localeCompare(b.startedAt)
    );
  }

  addMessage(message: ChatMessage): void {
    const existing = this.messages.get(message.sessionId) ?? [];
    existing.push(message);
    this.messages.set(message.sessionId, existing);
  }

  replaceMessage(message: ChatMessage): void {
    const existing = this.messages.get(message.sessionId) ?? [];
    const index = existing.findIndex((item) => item.id === message.id);

    if (index === -1) {
      existing.push(message);
    } else {
      existing[index] = message;
    }

    this.messages.set(message.sessionId, existing);
  }

  getMessages(sessionId: string): ChatMessage[] {
    return this.messages.get(sessionId) ?? [];
  }

  addPushToken(token: string): void {
    this.pushTokens.add(token);
  }

  getPushTokens(): string[] {
    return Array.from(this.pushTokens);
  }

  saveNotification(event: NotificationEvent): void {
    this.notificationEvents.push(event);
  }

  getNotificationSettings(): NotificationSettings {
    return this.notificationSettings;
  }

  updateNotificationSettings(settings: NotificationSettings): NotificationSettings {
    this.notificationSettings = settings;
    return settings;
  }
}
