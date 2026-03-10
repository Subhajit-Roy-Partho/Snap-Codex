import { URL } from "node:url";
import { constants as fsConstants } from "node:fs";
import { access, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import cors from "@fastify/cors";
import jwt from "@fastify/jwt";
import websocket from "@fastify/websocket";
import {
  ClientEventSchema,
  CreateTerminalSessionRequestSchema,
  CreateSessionRequestSchema,
  NotificationSettingsSchema,
  RegisterPushTokenRequestSchema,
  ResumeSessionRequestSchema,
  SendMessageRequestSchema,
  SessionActionRequestSchema,
  TerminalInputRequestSchema,
  TerminalResizeRequestSchema,
  type ServerEvent
} from "@codex/contracts";
import { config as baseConfig, type AppConfig } from "./config.js";
import { createRuntime, type CodexRuntime } from "./adapters/codexRuntime.js";
import { ProjectScanner } from "./services/projectScanner.js";
import { NotificationService } from "./services/notificationService.js";
import { ProjectFileService } from "./services/projectFileService.js";
import { SessionManager } from "./services/sessionManager.js";
import { ProjectRootsStore } from "./services/projectRootsStore.js";
import { TerminalManager } from "./services/terminalManager.js";
import {
  buildCollaborationModeCatalog,
  buildModelCatalog,
  buildProfileCatalog
} from "./services/catalog.js";
import { InMemoryStore } from "./store/inMemoryStore.js";

type CreateAppOptions = {
  config?: Partial<AppConfig>;
  runtime?: CodexRuntime;
};

const extractAuthToken = (request: FastifyRequest): string | null => {
  const bearer = request.headers.authorization;
  if (bearer?.startsWith("Bearer ")) {
    return bearer.slice("Bearer ".length);
  }

  const apiToken = request.headers["x-api-token"];
  if (typeof apiToken === "string") {
    return apiToken;
  }

  return null;
};

const getSessionIdFromEvent = (event: ServerEvent): string | null => {
  if (event.type === "session.started") {
    return event.payload.id;
  }

  if ("sessionId" in event.payload) {
    return (event.payload as { sessionId: string }).sessionId;
  }

  return null;
};

const parseLimit = (value: unknown, fallback: number, max: number): number => {
  const parsed = Number(value ?? fallback);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }

  return Math.min(Math.floor(parsed), max);
};

const expandLeadingTilde = (inputPath: string): string =>
  inputPath.startsWith("~")
    ? path.join(homedir(), inputPath.slice(1).replace(/^[/\\]/, ""))
    : inputPath;

const resolveBackendPath = (inputPath: string, basePath = process.cwd()): string => {
  const normalized = expandLeadingTilde(inputPath.trim());
  if (!normalized) {
    return path.resolve(basePath);
  }

  if (path.isAbsolute(normalized)) {
    return path.resolve(normalized);
  }

  return path.resolve(basePath, normalized);
};

export const createApp = async (options: CreateAppOptions = {}) => {
  const config: AppConfig = {
    ...baseConfig,
    ...options.config
  };

  const app = Fastify({ logger: true });

  await app.register(cors, {
    origin: true
  });

  await app.register(jwt, {
    secret: config.jwtSecret
  });

  await app.register(websocket);

  const store = new InMemoryStore();
  const persistedRootsStore = new ProjectRootsStore(config.projectRootsStorePath);
  const persistedRoots = await persistedRootsStore.load();
  const mergedRoots = Array.from(
    new Set([...config.allowedProjectRoots, ...persistedRoots].map((root) => path.resolve(root)))
  );
  const profiles = buildProfileCatalog();
  const catalogs = {
    models: buildModelCatalog(config.modelCatalogOverride),
    profiles
  };
  const collaborationModes = buildCollaborationModeCatalog();
  const scanner = new ProjectScanner(mergedRoots);
  const notificationService = new NotificationService(store, app.log, {
    enablePush: config.enablePush,
    firebaseServiceAccountJson: config.firebaseServiceAccountJson
  });
  const runtime =
    options.runtime ??
    createRuntime({
      mode: config.codexRuntime,
      command: config.codexCommand,
      args: config.codexArgs
    });

  const sessionManager = new SessionManager(
    store,
    catalogs,
    () => store.getProjects(),
    runtime,
    notificationService
  );
  const terminalManager = new TerminalManager();
  const projectFileService = new ProjectFileService(() => store.getProjects());

  const refreshModels = async (): Promise<void> => {
    try {
      const runtimeModels = await runtime.listModels();
      if (runtimeModels.length > 0) {
        catalogs.models = runtimeModels;
      }
    } catch (error) {
      app.log.warn(
        { err: error },
        "Unable to fetch models from runtime. Falling back to static catalog."
      );
    }
  };

  const refreshProjects = async (): Promise<void> => {
    const scanned = await scanner.scan();
    store.upsertProjects(scanned);
    await sessionManager.broadcastProjectUpdate(store.getProjects());
  };

  let scanTimer: NodeJS.Timeout | undefined;

  app.addHook("onReady", async () => {
    const runtimeHealth = await runtime.healthCheck();
    if (config.codexRuntime !== "mock" && !runtimeHealth.ready) {
      throw new Error(
        `Codex runtime is not ready: ${runtimeHealth.error ?? "health checks failed"}`
      );
    }

    await refreshModels();
    await refreshProjects();
    scanTimer = setInterval(() => {
      void refreshProjects();
    }, 45_000);
  });

  app.addHook("onClose", async () => {
    if (scanTimer) {
      clearInterval(scanTimer);
    }

    terminalManager.shutdown();
    await runtime.shutdown();
  });

  app.addHook("preHandler", async (request, reply) => {
    const isPublicEndpoint =
      request.url.startsWith("/health") || request.url.startsWith("/auth/token/verify");
    const isWebSocketUpgrade = request.url.startsWith("/ws");

    if (isPublicEndpoint || isWebSocketUpgrade) {
      return;
    }

    const authToken = extractAuthToken(request);
    if (authToken === config.authToken) {
      return;
    }

    try {
      await request.jwtVerify();
    } catch {
      return reply.code(401).send({ error: "Unauthorized" });
    }
  });

  app.get("/health", async (_request, reply) => {
    const runtimeHealth = await runtime.healthCheck();
    const response = {
      ok: runtimeHealth.ready,
      ready: runtimeHealth.ready,
      runtime: runtimeHealth
    };

    if (!runtimeHealth.ready) {
      return reply.code(503).send(response);
    }

    return response;
  });

  app.post("/auth/token/verify", async (request, reply) => {
    const body =
      typeof request.body === "object" && request.body !== null
        ? (request.body as { token?: string })
        : {};

    if (body.token !== config.authToken) {
      return reply.code(401).send({ ok: false, error: "Invalid token" });
    }

    const signedJwt = await reply.jwtSign({
      sub: "codex-mobile-user",
      scope: "all"
    });

    return {
      ok: true,
      jwt: signedJwt
    };
  });

  app.get("/project-roots", async () => ({ roots: scanner.getRoots() }));
  app.post("/project-roots", async (request, reply) => {
    const body =
      typeof request.body === "object" && request.body !== null
        ? (request.body as { path?: string })
        : {};
    const inputPath = `${body.path ?? ""}`.trim();
    if (!inputPath) {
      return reply.code(400).send({ error: "Path is required." });
    }

    const resolved = resolveBackendPath(inputPath);

    let metadata;
    try {
      metadata = await stat(resolved);
    } catch {
      return reply.code(400).send({ error: "Path does not exist." });
    }

    if (!metadata.isDirectory()) {
      return reply.code(400).send({ error: "Path must be a directory." });
    }

    scanner.addRoot(resolved);
    await persistedRootsStore.save(scanner.getRoots());
    await refreshProjects();

    return {
      roots: scanner.getRoots(),
      projects: store.getProjects()
    };
  });

  app.get("/fs/dirs", async (request, reply) => {
    const query = request.query as {
      path?: string;
      limit?: string | number;
    };

    const resolvedPath = resolveBackendPath(query.path?.trim() || ".");
    const limit = parseLimit(query.limit, 200, 500);

    let metadata;
    try {
      metadata = await stat(resolvedPath);
    } catch {
      return reply.code(404).send({ error: "Path does not exist." });
    }

    if (!metadata.isDirectory()) {
      return reply.code(400).send({ error: "Path must be a directory." });
    }

    let entries;
    try {
      entries = await readdir(resolvedPath, { withFileTypes: true });
    } catch {
      return reply.code(403).send({ error: "Path is not readable." });
    }

    const directories = entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => ({
        name: entry.name,
        path: path.join(resolvedPath, entry.name)
      }))
      .sort((a, b) => a.name.localeCompare(b.name))
      .slice(0, limit);

    const entriesWithAccess = await Promise.all(
      directories.map(async (entry) => {
        let readable = true;
        try {
          await access(entry.path, fsConstants.R_OK | fsConstants.X_OK);
        } catch {
          readable = false;
        }

        return {
          ...entry,
          readable
        };
      })
    );

    const parentPath = path.dirname(resolvedPath);

    return {
      resolvedPath,
      parentPath: parentPath === resolvedPath ? null : parentPath,
      entries: entriesWithAccess
    };
  });

  app.get("/fs/dir-suggest", async (request, reply) => {
    const query = request.query as {
      query?: string;
      base?: string;
      limit?: string | number;
    };

    const rawQuery = query.query?.trim() ?? "";
    const limit = parseLimit(query.limit, 20, 100);

    const expandedQuery = expandLeadingTilde(rawQuery);
    const isAnchoredQuery =
      expandedQuery.startsWith(".") ||
      path.isAbsolute(expandedQuery) ||
      expandedQuery.includes(path.sep);

    const queryEndsWithSeparator = expandedQuery.endsWith(path.sep);
    const prefix = rawQuery.length === 0 || queryEndsWithSeparator
      ? ""
      : path.basename(expandedQuery);
    const parentCandidate = isAnchoredQuery
      ? queryEndsWithSeparator
        ? expandedQuery
        : path.dirname(expandedQuery)
      : (query.base?.trim() || ".");
    const resolvedBasePath = resolveBackendPath(parentCandidate || ".", query.base?.trim() || ".");

    let metadata;
    try {
      metadata = await stat(resolvedBasePath);
    } catch {
      return reply.code(404).send({ error: "Base path does not exist." });
    }

    if (!metadata.isDirectory()) {
      return reply.code(400).send({ error: "Base path must be a directory." });
    }

    let entries;
    try {
      entries = await readdir(resolvedBasePath, { withFileTypes: true });
    } catch {
      return reply.code(403).send({ error: "Base path is not readable." });
    }

    const normalizedPrefix = prefix.toLowerCase();
    const rankedSuggestions = entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const lowerName = entry.name.toLowerCase();
        const startsWith = normalizedPrefix.length === 0 || lowerName.startsWith(normalizedPrefix);
        const includes = normalizedPrefix.length > 0 && lowerName.includes(normalizedPrefix);
        const score = startsWith ? 2 : includes ? 1 : 0;
        return {
          path: path.join(resolvedBasePath, entry.name),
          score
        };
      })
      .filter((entry) => entry.score > 0 || normalizedPrefix.length === 0)
      .sort((a, b) => {
        if (b.score !== a.score) {
          return b.score - a.score;
        }
        return a.path.localeCompare(b.path);
      })
      .slice(0, limit)
      .map((entry) => entry.path);

    return {
      resolvedBasePath,
      suggestions: rankedSuggestions
    };
  });

  app.get("/projects", async () => ({ projects: store.getProjects() }));
  app.post("/projects/scan", async () => {
    await refreshProjects();
    return { projects: store.getProjects() };
  });
  app.get("/projects/:id/files", async (request, reply) => {
    const params = request.params as { id: string };
    const query = request.query as {
      path?: string;
      limit?: string | number;
    };

    try {
      const listing = await projectFileService.listDirectory(
        params.id,
        query.path?.trim() ?? "",
        parseLimit(query.limit, 400, 800)
      );
      return listing;
    } catch (error) {
      const message = (error as Error).message;
      const statusCode =
        message.includes("not found")
          ? 404
          : message.includes("not readable")
            ? 403
            : 400;
      return reply.code(statusCode).send({ error: message });
    }
  });
  app.get("/projects/:id/files/content", async (request, reply) => {
    const params = request.params as { id: string };
    const query = request.query as {
      path?: string;
    };

    try {
      const document = await projectFileService.readDocument(
        params.id,
        query.path?.trim() ?? ""
      );
      return document;
    } catch (error) {
      const message = (error as Error).message;
      const statusCode =
        message.includes("does not exist") || message.includes("not found")
          ? 404
          : message.includes("not readable")
            ? 403
            : 400;
      return reply.code(statusCode).send({ error: message });
    }
  });
  app.put("/projects/:id/files/content", async (request, reply) => {
    const params = request.params as { id: string };
    const body =
      typeof request.body === "object" && request.body !== null
        ? (request.body as { path?: string; content?: string })
        : {};
    const inputPath = `${body.path ?? ""}`.trim();

    if (!inputPath) {
      return reply.code(400).send({ error: "File path is required." });
    }
    if (typeof body.content !== "string") {
      return reply.code(400).send({ error: "File content must be a string." });
    }

    try {
      const document = await projectFileService.writeDocument(
        params.id,
        inputPath,
        body.content
      );
      return document;
    } catch (error) {
      const message = (error as Error).message;
      const statusCode = message.includes("not found") ? 404 : 400;
      return reply.code(statusCode).send({ error: message });
    }
  });
  app.post("/projects/:id/files/upload", async (request, reply) => {
    const params = request.params as { id: string };
    const body =
      typeof request.body === "object" && request.body !== null
        ? (request.body as {
            directoryPath?: string;
            fileName?: string;
            contentBase64?: string;
          })
        : {};
    const fileName = `${body.fileName ?? ""}`.trim();
    const contentBase64 = `${body.contentBase64 ?? ""}`.trim();

    if (!fileName) {
      return reply.code(400).send({ error: "File name is required." });
    }
    if (!contentBase64) {
      return reply.code(400).send({ error: "File content is required." });
    }

    try {
      const file = await projectFileService.uploadFile(
        params.id,
        `${body.directoryPath ?? ""}`.trim(),
        fileName,
        contentBase64
      );
      return { file };
    } catch (error) {
      const message = (error as Error).message;
      const statusCode = message.includes("not found") ? 404 : 400;
      return reply.code(statusCode).send({ error: message });
    }
  });
  app.get("/projects/:id/files/download", async (request, reply) => {
    const params = request.params as { id: string };
    const query = request.query as { path?: string };
    const inputPath = query.path?.trim() ?? "";
    if (!inputPath) {
      return reply.code(400).send({ error: "File path is required." });
    }

    try {
      const download = await projectFileService.downloadFile(params.id, inputPath);
      reply.header("content-type", download.contentType);
      reply.header("x-codex-file-name", download.fileName);
      reply.header(
        "content-disposition",
        `attachment; filename="${encodeURIComponent(download.fileName)}"`
      );
      return reply.send(download.data);
    } catch (error) {
      const message = (error as Error).message;
      const statusCode =
        message.includes("does not exist") || message.includes("not found")
          ? 404
          : 400;
      return reply.code(statusCode).send({ error: message });
    }
  });
  app.get("/models", async () => ({ models: catalogs.models }));
  app.get("/profiles", async () => ({ profiles }));
  app.get("/collaboration-modes", async () => ({ modes: collaborationModes }));
  app.get("/history", async (request) => {
    const query = request.query as {
      cwd?: string;
      cursor?: string;
      limit?: string | number;
    };

    const limit = Number(query.limit ?? 20);
    const history = await sessionManager.listHistory({
      cwd: query.cwd?.trim() || undefined,
      cursor: query.cursor?.trim() || undefined,
      limit: Number.isFinite(limit) && limit > 0 ? limit : 20
    });

    return history;
  });
  app.get("/sessions", async () => ({ sessions: store.listSessions() }));
  app.get("/terminal/sessions", async () => ({
    sessions: terminalManager.listSessions()
  }));

  app.post("/terminal/sessions", async (request, reply) => {
    const parsed = CreateTerminalSessionRequestSchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const snapshot = await terminalManager.createSession({
        cwd: parsed.data.cwd,
        shell: parsed.data.shell,
        bootstrap: parsed.data.bootstrap,
        cols: parsed.data.cols,
        rows: parsed.data.rows
      });
      return snapshot;
    } catch (error) {
      return reply.code(400).send({ error: (error as Error).message });
    }
  });

  app.get("/terminal/sessions/:id", async (request, reply) => {
    const params = request.params as { id: string };
    try {
      const snapshot = terminalManager.getSnapshot(params.id);
      return snapshot;
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.post("/terminal/sessions/:id/input", async (request, reply) => {
    const params = request.params as { id: string };
    const parsed = TerminalInputRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      terminalManager.writeInput(params.id, parsed.data.input);
      return { ok: true };
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.post("/terminal/sessions/:id/resize", async (request, reply) => {
    const params = request.params as { id: string };
    const parsed = TerminalResizeRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      terminalManager.resizeSession(params.id, {
        cols: parsed.data.cols,
        rows: parsed.data.rows
      });
      return { ok: true };
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.delete("/terminal/sessions/:id", async (request) => {
    const params = request.params as { id: string };
    terminalManager.closeSession(params.id);
    return { ok: true };
  });

  app.post("/sessions", async (request, reply) => {
    const parsed = CreateSessionRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const session = sessionManager.createSession(parsed.data);
      return { session };
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.post("/sessions/resume", async (request, reply) => {
    const parsed = ResumeSessionRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const result = await sessionManager.resumeSession(parsed.data);
      return result;
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.get("/sessions/:id", async (request, reply) => {
    const params = request.params as { id: string };
    const session = sessionManager.getSession(params.id);
    if (!session) {
      return reply.code(404).send({ error: "Session not found" });
    }

    return { session };
  });

  app.get("/sessions/:id/messages", async (request) => {
    const params = request.params as { id: string };
    return { messages: sessionManager.getMessages(params.id) };
  });

  app.post("/sessions/:id/messages", async (request, reply) => {
    const params = request.params as { id: string };
    const parsed = SendMessageRequestSchema.safeParse(request.body);

    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const message = await sessionManager.sendMessage(
        params.id,
        parsed.data.content,
        parsed.data.requestPermission
      );
      return reply.code(202).send({ message });
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.post("/sessions/:id/actions", async (request, reply) => {
    const params = request.params as { id: string };
    const parsed = SessionActionRequestSchema.safeParse(request.body);

    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      await sessionManager.handleAction(params.id, parsed.data);
      return { ok: true };
    } catch (error) {
      return reply.code(404).send({ error: (error as Error).message });
    }
  });

  app.post("/devices/push-token", async (request, reply) => {
    const parsed = RegisterPushTokenRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    store.addPushToken(parsed.data.token);
    return { ok: true };
  });

  app.get("/settings/notifications", async () => ({
    settings: notificationService.getSettings()
  }));

  app.put("/settings/notifications", async (request, reply) => {
    const parsed = NotificationSettingsSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    return {
      settings: notificationService.updateSettings(parsed.data)
    };
  });

  app.get(
    "/ws",
    { websocket: true },
    (socket, request: FastifyRequest<{ Querystring: { token?: string } }>) => {
      const url = new URL(request.url, "http://localhost");
      const queryToken = url.searchParams.get("token");
      const token = queryToken ?? extractAuthToken(request);

      if (token !== config.authToken) {
        socket.close(1008, "Unauthorized");
        return;
      }

      const subscriptions = new Set<string>();
      const terminalSubscriptions = new Set<string>();

      const off = sessionManager.onServerEvent((event) => {
        const sessionId = getSessionIdFromEvent(event);
        const isGlobalEvent =
          event.type === "project.scan.updated" || event.type === "notification.dispatched";

        if (!isGlobalEvent && sessionId && !subscriptions.has(sessionId)) {
          return;
        }

        socket.send(JSON.stringify(event));
      });
      const offTerminal = terminalManager.onEvent((event) => {
        const terminalId = event.payload.terminalId;
        if (!terminalSubscriptions.has(terminalId)) {
          return;
        }

        socket.send(JSON.stringify(event));
      });

      socket.on("message", (raw) => {
        let parsedRaw: unknown;

        try {
          parsedRaw = JSON.parse(raw.toString());
        } catch {
          socket.send(
            JSON.stringify({
              type: "error",
              payload: { code: "invalid_json", message: "Invalid JSON payload" }
            })
          );
          return;
        }

        const eventParse = ClientEventSchema.safeParse(parsedRaw);
        if (!eventParse.success) {
          socket.send(
            JSON.stringify({
              type: "error",
              payload: {
                code: "invalid_event",
                message: eventParse.error.flatten()
              }
            })
          );
          return;
        }

        const clientEvent = eventParse.data;

        if (clientEvent.type === "session.subscribe") {
          subscriptions.add(clientEvent.payload.sessionId);
          socket.send(
            JSON.stringify({
              type: "session.state.changed",
              payload: {
                sessionId: clientEvent.payload.sessionId,
                status:
                  sessionManager.getSession(clientEvent.payload.sessionId)?.status ?? "idle"
              }
            })
          );
          for (const message of sessionManager.getMessages(clientEvent.payload.sessionId)) {
            socket.send(JSON.stringify({ type: "message.completed", payload: message }));
          }
          return;
        }

        if (clientEvent.type === "session.unsubscribe") {
          subscriptions.delete(clientEvent.payload.sessionId);
          return;
        }

        if (clientEvent.type === "terminal.subscribe") {
          terminalSubscriptions.add(clientEvent.payload.terminalId);
          try {
            const snapshot = terminalManager.getSnapshot(clientEvent.payload.terminalId);
            socket.send(
              JSON.stringify({
                type: "terminal.snapshot",
                payload: snapshot
              })
            );
          } catch (error) {
            socket.send(
              JSON.stringify({
                type: "error",
                payload: {
                  code: "terminal_not_found",
                  message: (error as Error).message
                }
              })
            );
          }
          return;
        }

        if (clientEvent.type === "terminal.unsubscribe") {
          terminalSubscriptions.delete(clientEvent.payload.terminalId);
          return;
        }

        if (clientEvent.type === "terminal.input") {
          try {
            terminalManager.writeInput(clientEvent.payload.terminalId, clientEvent.payload.input);
          } catch (error) {
            socket.send(
              JSON.stringify({
                type: "error",
                payload: {
                  code: "terminal_write_failed",
                  message: (error as Error).message
                }
              })
            );
          }
          return;
        }

        if (clientEvent.type === "terminal.resize") {
          try {
            terminalManager.resizeSession(clientEvent.payload.terminalId, {
              cols: clientEvent.payload.cols,
              rows: clientEvent.payload.rows
            });
          } catch (error) {
            socket.send(
              JSON.stringify({
                type: "error",
                payload: {
                  code: "terminal_resize_failed",
                  message: (error as Error).message
                }
              })
            );
          }
          return;
        }

        if (clientEvent.type === "message.send") {
          void sessionManager.sendMessage(
            clientEvent.payload.sessionId,
            clientEvent.payload.content,
            false
          );
          return;
        }

        if (clientEvent.type === "session.interrupt") {
          void sessionManager.handleAction(clientEvent.payload.sessionId, {
            action: "interrupt"
          });
          return;
        }

        if (clientEvent.type === "permission.response") {
          void sessionManager.resolvePermission(
            clientEvent.payload.sessionId,
            clientEvent.payload.requestId,
            clientEvent.payload.approved
          );
          return;
        }

        if (clientEvent.type === "user.input.respond") {
          void sessionManager.resolveUserInput(
            clientEvent.payload.sessionId,
            clientEvent.payload.requestId,
            clientEvent.payload.answers
          );
        }
      });

      socket.on("close", () => {
        off();
        offTerminal();
      });
    }
  );

  return app;
};

export const startServer = async (options: CreateAppOptions = {}): Promise<void> => {
  const app = await createApp(options);
  const config = {
    ...baseConfig,
    ...options.config
  };

  await app.listen({
    port: config.port,
    host: config.host
  });
};
