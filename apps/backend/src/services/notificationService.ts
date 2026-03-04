import type { FastifyBaseLogger } from "fastify";
import admin from "firebase-admin";
import type {
  NotificationEvent,
  NotificationSettings,
  NotificationType
} from "@codex/contracts";
import { v4 as uuidv4 } from "uuid";
import { InMemoryStore } from "../store/inMemoryStore.js";

const DEDUP_MS = 750;

export class NotificationService {
  private recentDispatches = new Map<string, number>();
  private initialized = false;

  constructor(
    private readonly store: InMemoryStore,
    private readonly logger: FastifyBaseLogger,
    private readonly options: {
      enablePush: boolean;
      firebaseServiceAccountJson?: string;
    }
  ) {
    this.initializePushClient();
  }

  getSettings(): NotificationSettings {
    return this.store.getNotificationSettings();
  }

  updateSettings(settings: NotificationSettings): NotificationSettings {
    return this.store.updateNotificationSettings(settings);
  }

  async dispatch(
    type: NotificationType,
    payload: Record<string, unknown>,
    sessionId: string | null
  ): Promise<NotificationEvent> {
    const event: NotificationEvent = {
      id: uuidv4(),
      sessionId,
      type,
      payload,
      createdAt: new Date().toISOString(),
      pushSentAt: null
    };

    this.store.saveNotification(event);

    if (!this.getSettings()[type]) {
      return event;
    }

    const dedupKey = `${type}:${sessionId ?? "global"}`;
    const now = Date.now();
    const previous = this.recentDispatches.get(dedupKey) ?? 0;

    if (now - previous < DEDUP_MS) {
      return event;
    }

    this.recentDispatches.set(dedupKey, now);

    if (!this.options.enablePush || !this.initialized) {
      return event;
    }

    const pushTokens = this.store.getPushTokens();
    if (pushTokens.length === 0) {
      return event;
    }

    await Promise.all(
      pushTokens.map(async (token) => {
        try {
          await admin.messaging().send({
            token,
            data: {
              eventId: event.id,
              type,
              sessionId: sessionId ?? ""
            },
            notification: {
              title: `Codex ${type} event`,
              body: JSON.stringify(payload).slice(0, 120)
            }
          });
          event.pushSentAt = new Date().toISOString();
        } catch (error) {
          this.logger.warn({ error, token }, "Push dispatch failed");
        }
      })
    );

    return event;
  }

  private initializePushClient(): void {
    if (!this.options.enablePush || this.initialized) {
      return;
    }

    try {
      if (this.options.firebaseServiceAccountJson) {
        const serviceAccount = JSON.parse(this.options.firebaseServiceAccountJson);
        admin.initializeApp({
          credential: admin.credential.cert(serviceAccount)
        });
      } else {
        admin.initializeApp();
      }
      this.initialized = true;
      this.logger.info("Firebase push notifications enabled");
    } catch (error) {
      this.initialized = false;
      this.logger.warn({ error }, "Firebase initialization failed, disabling push");
    }
  }
}
