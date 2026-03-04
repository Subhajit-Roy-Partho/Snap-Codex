import { z } from "zod";

export const SessionStatusSchema = z.enum([
  "idle",
  "running",
  "awaiting_permission",
  "completed",
  "failed",
  "cancelled"
]);
export type SessionStatus = z.infer<typeof SessionStatusSchema>;

export const ProjectSchema = z.object({
  id: z.string(),
  name: z.string(),
  path: z.string(),
  gitBranch: z.string().nullable(),
  gitDirty: z.boolean(),
  lastSeenAt: z.string()
});
export type Project = z.infer<typeof ProjectSchema>;

export const ModelSchema = z.object({
  id: z.string(),
  displayName: z.string(),
  capabilities: z.array(z.string()),
  defaultProfileIds: z.array(z.string()),
  supportedReasoningEfforts: z.array(
    z.enum(["low", "medium", "high", "xhigh"])
  ),
  defaultReasoningEffort: z.enum(["low", "medium", "high", "xhigh"])
});
export type Model = z.infer<typeof ModelSchema>;

export const ReasoningEffortSchema = z.enum([
  "low",
  "medium",
  "high",
  "xhigh"
]);
export type ReasoningEffort = z.infer<typeof ReasoningEffortSchema>;

export const CollaborationModeSchema = z.enum(["default", "plan"]);
export type CollaborationMode = z.infer<typeof CollaborationModeSchema>;

export const CollaborationModeOptionSchema = z.object({
  id: CollaborationModeSchema,
  name: z.string(),
  description: z.string()
});
export type CollaborationModeOption = z.infer<typeof CollaborationModeOptionSchema>;

export const PermissionProfileSchema = z.object({
  id: z.string(),
  name: z.string(),
  codexFlags: z.array(z.string()),
  guardrails: z.object({
    blockDestructiveShell: z.boolean(),
    requirePermissionPrompts: z.boolean()
  })
});
export type PermissionProfile = z.infer<typeof PermissionProfileSchema>;

export const ChatSessionSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  modelId: z.string(),
  profileId: z.string(),
  collaborationMode: CollaborationModeSchema,
  reasoningEffort: ReasoningEffortSchema,
  threadId: z.string().nullable(),
  status: SessionStatusSchema,
  startedAt: z.string(),
  endedAt: z.string().nullable()
});
export type ChatSession = z.infer<typeof ChatSessionSchema>;

export const ChatMessageSchema = z.object({
  id: z.string(),
  sessionId: z.string(),
  role: z.enum(["user", "assistant", "system", "tool"]),
  content: z.string(),
  createdAt: z.string()
});
export type ChatMessage = z.infer<typeof ChatMessageSchema>;

export const TerminalSessionSchema = z.object({
  id: z.string(),
  cwd: z.string(),
  shell: z.string(),
  running: z.boolean(),
  startedAt: z.string(),
  endedAt: z.string().nullable()
});
export type TerminalSession = z.infer<typeof TerminalSessionSchema>;

export const CreateTerminalSessionRequestSchema = z.object({
  cwd: z.string().optional(),
  shell: z.string().optional(),
  bootstrap: z.array(z.string()).optional(),
  cols: z.number().int().min(20).max(400).optional(),
  rows: z.number().int().min(5).max(200).optional()
});
export type CreateTerminalSessionRequest = z.infer<
  typeof CreateTerminalSessionRequestSchema
>;

export const TerminalInputRequestSchema = z.object({
  input: z.string()
});
export type TerminalInputRequest = z.infer<typeof TerminalInputRequestSchema>;

export const TerminalResizeRequestSchema = z.object({
  cols: z.number().int().min(20).max(400),
  rows: z.number().int().min(5).max(200)
});
export type TerminalResizeRequest = z.infer<typeof TerminalResizeRequestSchema>;

export const NotificationTypeSchema = z.enum([
  "message",
  "tool",
  "permission",
  "session",
  "error"
]);
export type NotificationType = z.infer<typeof NotificationTypeSchema>;

export const NotificationEventSchema = z.object({
  id: z.string(),
  sessionId: z.string().nullable(),
  type: NotificationTypeSchema,
  payload: z.record(z.unknown()),
  createdAt: z.string(),
  pushSentAt: z.string().nullable()
});
export type NotificationEvent = z.infer<typeof NotificationEventSchema>;

export const CreateSessionRequestSchema = z.object({
  projectId: z.string(),
  modelId: z.string(),
  profileId: z.string(),
  reasoningEffort: ReasoningEffortSchema.optional().default("medium"),
  collaborationMode: CollaborationModeSchema.optional().default("default")
});
export type CreateSessionRequest = z.infer<typeof CreateSessionRequestSchema>;

export const ResumeSessionRequestSchema = z.object({
  threadId: z.string(),
  projectId: z.string(),
  modelId: z.string(),
  profileId: z.string(),
  reasoningEffort: ReasoningEffortSchema.optional().default("medium"),
  collaborationMode: CollaborationModeSchema.optional().default("default")
});
export type ResumeSessionRequest = z.infer<typeof ResumeSessionRequestSchema>;

export const HistoryThreadSchema = z.object({
  threadId: z.string(),
  preview: z.string(),
  cwd: z.string().nullable(),
  createdAt: z.string(),
  updatedAt: z.string(),
  status: z.string()
});
export type HistoryThread = z.infer<typeof HistoryThreadSchema>;

export const SendMessageRequestSchema = z.object({
  content: z.string().min(1),
  requestPermission: z.boolean().optional().default(false)
});
export type SendMessageRequest = z.infer<typeof SendMessageRequestSchema>;

export const SessionActionRequestSchema = z.object({
  action: z.enum(["interrupt", "retry", "approve", "deny"]),
  requestId: z.string().optional(),
  reason: z.string().optional()
});
export type SessionActionRequest = z.infer<typeof SessionActionRequestSchema>;

export const RegisterPushTokenRequestSchema = z.object({
  token: z.string().min(1),
  platform: z.enum(["android", "ios"])
});
export type RegisterPushTokenRequest = z.infer<typeof RegisterPushTokenRequestSchema>;

export const NotificationSettingsSchema = z.object({
  message: z.boolean(),
  tool: z.boolean(),
  permission: z.boolean(),
  session: z.boolean(),
  error: z.boolean()
});
export type NotificationSettings = z.infer<typeof NotificationSettingsSchema>;

export const HealthCheckItemSchema = z.object({
  name: z.string(),
  ok: z.boolean(),
  message: z.string()
});
export type HealthCheckItem = z.infer<typeof HealthCheckItemSchema>;

export const HealthStatusSchema = z.object({
  ok: z.boolean(),
  ready: z.boolean(),
  runtime: z.object({
    mode: z.string(),
    transport: z.string(),
    command: z.string(),
    args: z.array(z.string()),
    version: z.string().nullable(),
    lastCheckedAt: z.string(),
    checks: z.array(HealthCheckItemSchema),
    error: z.string().nullable()
  })
});
export type HealthStatus = z.infer<typeof HealthStatusSchema>;

export const ServerEventSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("session.started"),
    payload: ChatSessionSchema
  }),
  z.object({
    type: z.literal("message.delta"),
    payload: z.object({
      sessionId: z.string(),
      messageId: z.string(),
      delta: z.string()
    })
  }),
  z.object({
    type: z.literal("message.completed"),
    payload: ChatMessageSchema
  }),
  z.object({
    type: z.literal("tool.started"),
    payload: z.object({
      sessionId: z.string(),
      toolName: z.string(),
      inputSummary: z.string()
    })
  }),
  z.object({
    type: z.literal("tool.completed"),
    payload: z.object({
      sessionId: z.string(),
      toolName: z.string(),
      success: z.boolean(),
      outputSummary: z.string()
    })
  }),
  z.object({
    type: z.literal("permission.requested"),
    payload: z.object({
      sessionId: z.string(),
      requestId: z.string(),
      prompt: z.string()
    })
  }),
  z.object({
    type: z.literal("permission.resolved"),
    payload: z.object({
      sessionId: z.string(),
      requestId: z.string(),
      approved: z.boolean()
    })
  }),
  z.object({
    type: z.literal("user.input.requested"),
    payload: z.object({
      sessionId: z.string(),
      requestId: z.string(),
      questions: z.array(
        z.object({
          header: z.string(),
          id: z.string(),
          question: z.string(),
          options: z.array(
            z.object({
              label: z.string(),
              description: z.string()
            })
          )
        })
      )
    })
  }),
  z.object({
    type: z.literal("user.input.resolved"),
    payload: z.object({
      sessionId: z.string(),
      requestId: z.string()
    })
  }),
  z.object({
    type: z.literal("session.state.changed"),
    payload: z.object({
      sessionId: z.string(),
      status: SessionStatusSchema
    })
  }),
  z.object({
    type: z.literal("turn.diff.updated"),
    payload: z.object({
      sessionId: z.string(),
      turnId: z.string(),
      diff: z.string()
    })
  }),
  z.object({
    type: z.literal("project.scan.updated"),
    payload: z.object({
      projects: z.array(ProjectSchema)
    })
  }),
  z.object({
    type: z.literal("terminal.started"),
    payload: z.object({
      terminalId: z.string(),
      cwd: z.string(),
      shell: z.string(),
      running: z.boolean(),
      startedAt: z.string()
    })
  }),
  z.object({
    type: z.literal("terminal.snapshot"),
    payload: z.object({
      session: TerminalSessionSchema,
      output: z.string()
    })
  }),
  z.object({
    type: z.literal("terminal.output"),
    payload: z.object({
      terminalId: z.string(),
      stream: z.enum(["stdout", "stderr"]),
      data: z.string(),
      timestamp: z.string()
    })
  }),
  z.object({
    type: z.literal("terminal.exited"),
    payload: z.object({
      terminalId: z.string(),
      exitCode: z.number().nullable(),
      signal: z.string().nullable(),
      timestamp: z.string()
    })
  }),
  z.object({
    type: z.literal("notification.dispatched"),
    payload: NotificationEventSchema
  }),
  z.object({
    type: z.literal("error"),
    payload: z.object({
      code: z.string(),
      message: z.string(),
      sessionId: z.string().optional()
    })
  })
]);
export type ServerEvent = z.infer<typeof ServerEventSchema>;

export const ClientEventSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("session.subscribe"),
    payload: z.object({ sessionId: z.string() })
  }),
  z.object({
    type: z.literal("session.unsubscribe"),
    payload: z.object({ sessionId: z.string() })
  }),
  z.object({
    type: z.literal("message.send"),
    payload: z.object({ sessionId: z.string(), content: z.string() })
  }),
  z.object({
    type: z.literal("session.interrupt"),
    payload: z.object({ sessionId: z.string() })
  }),
  z.object({
    type: z.literal("permission.response"),
    payload: z.object({
      sessionId: z.string(),
      requestId: z.string(),
      approved: z.boolean()
    })
  }),
  z.object({
    type: z.literal("user.input.respond"),
    payload: z.object({
      sessionId: z.string(),
      requestId: z.string(),
      answers: z.record(
        z.object({
          answers: z.array(z.string())
        })
      )
    })
  }),
  z.object({
    type: z.literal("terminal.subscribe"),
    payload: z.object({ terminalId: z.string() })
  }),
  z.object({
    type: z.literal("terminal.unsubscribe"),
    payload: z.object({ terminalId: z.string() })
  }),
  z.object({
    type: z.literal("terminal.input"),
    payload: z.object({
      terminalId: z.string(),
      input: z.string()
    })
  }),
  z.object({
    type: z.literal("terminal.resize"),
    payload: z.object({
      terminalId: z.string(),
      cols: z.number().int().min(20).max(400),
      rows: z.number().int().min(5).max(200)
    })
  })
]);
export type ClientEvent = z.infer<typeof ClientEventSchema>;

export const BACKEND_NOTIFICATION_TOPIC = "codex-events";
