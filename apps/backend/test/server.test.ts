import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/server.js";

describe("backend API", () => {
  const token = "test-token";
  let app: Awaited<ReturnType<typeof createApp>>;

  beforeAll(async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "codex-backend-test-"));
    const projectPath = path.join(tempRoot, "demo-project");
    await writeFile(path.join(tempRoot, "placeholder.txt"), "");

    await mkdir(projectPath);
    await writeFile(
      path.join(projectPath, "package.json"),
      JSON.stringify({ name: "demo-project", version: "1.0.0" })
    );

    app = await createApp({
      config: {
        authToken: token,
        allowedProjectRoots: [tempRoot],
        enablePush: false,
        codexRuntime: "mock"
      }
    });

    await app.ready();
  });

  afterAll(async () => {
    await app.close();
  });

  it("requires auth token for protected endpoints", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/projects"
    });

    expect(response.statusCode).toBe(401);
  });

  it("verifies auth token and returns JWT", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/auth/token/verify",
      payload: { token }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.ok).toBe(true);
    expect(typeof body.jwt).toBe("string");
  });

  it("returns runtime readiness details on /health", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/health"
    });

    expect(response.statusCode).toBe(200);
    const body = response.json() as {
      ok: boolean;
      ready: boolean;
      runtime: {
        mode: string;
        checks: Array<{ name: string; ok: boolean }>;
      };
    };

    expect(body.ok).toBe(true);
    expect(body.ready).toBe(true);
    expect(body.runtime.mode).toBe("mock");
    expect(body.runtime.checks.length).toBeGreaterThan(0);
    expect(body.runtime.checks.every((check) => check.ok)).toBe(true);
  });

  it("creates a session and streams assistant response", async () => {
    const projectResponse = await app.inject({
      method: "GET",
      url: "/projects",
      headers: { "x-api-token": token }
    });

    const projectBody = projectResponse.json() as {
      projects: Array<{ id: string }>;
    };

    expect(projectBody.projects.length).toBeGreaterThan(0);

    const sessionResponse = await app.inject({
      method: "POST",
      url: "/sessions",
      headers: { "x-api-token": token },
      payload: {
        projectId: projectBody.projects[0].id,
        modelId: "gpt-5-codex",
        profileId: "yolo"
      }
    });

    expect(sessionResponse.statusCode).toBe(200);
    const sessionBody = sessionResponse.json() as { session: { id: string } };

    const messageResponse = await app.inject({
      method: "POST",
      url: `/sessions/${sessionBody.session.id}/messages`,
      headers: { "x-api-token": token },
      payload: {
        content: "Hello Codex",
        requestPermission: false
      }
    });

    expect(messageResponse.statusCode).toBe(202);

    let messages: Array<{ role: string; content: string }> = [];
    for (let attempt = 0; attempt < 30; attempt += 1) {
      await delay(50);
      const messageListResponse = await app.inject({
        method: "GET",
        url: `/sessions/${sessionBody.session.id}/messages`,
        headers: { "x-api-token": token }
      });
      messages = (messageListResponse.json() as { messages: Array<{ role: string; content: string }> }).messages;
      const assistant = messages.find((message) => message.role === "assistant");
      if (assistant) {
        break;
      }
    }

    const assistantMessage = messages.find((message) => message.role === "assistant");
    expect(assistantMessage).toBeDefined();
    expect(assistantMessage?.content).toContain("Mock assistant response");
  });

  it("supports websocket event subscription", async () => {
    await app.listen({ host: "127.0.0.1", port: 0 });
    const address = app.server.address();

    if (!address || typeof address === "string") {
      throw new Error("Unable to resolve listening address");
    }

    const ws = new WebSocket(`ws://127.0.0.1:${address.port}/ws?token=${token}`);

    const events: Array<{ type: string }> = [];

    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", (error) => reject(error));
    });

    ws.on("message", (data) => {
      try {
        events.push(JSON.parse(data.toString()) as { type: string });
      } catch {
        // Ignore parse errors in test.
      }
    });

    const sessionsResponse = await app.inject({
      method: "GET",
      url: "/sessions",
      headers: { "x-api-token": token }
    });
    const sessions = (sessionsResponse.json() as { sessions: Array<{ id: string }> }).sessions;

    expect(sessions.length).toBeGreaterThan(0);

    ws.send(
      JSON.stringify({
        type: "session.subscribe",
        payload: { sessionId: sessions[0].id }
      })
    );

    ws.send(
      JSON.stringify({
        type: "message.send",
        payload: { sessionId: sessions[0].id, content: "stream this" }
      })
    );

    for (let attempt = 0; attempt < 40; attempt += 1) {
      await delay(50);
      if (events.some((event) => event.type === "message.delta")) {
        break;
      }
    }

    expect(events.some((event) => event.type === "message.delta")).toBe(true);

    ws.close();
  });
});
