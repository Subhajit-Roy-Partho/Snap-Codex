import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import WebSocket from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/server.js";

describe("backend API", () => {
  const token = "test-token";
  let app: Awaited<ReturnType<typeof createApp>>;

  const expectDemoProject = (
    projects: Array<{ id: string; path: string; name?: string }>
  ) => {
    const project = projects.find((entry) => entry.path.endsWith("/demo-project"));
    expect(project).toBeDefined();
    return project!;
  };

  beforeAll(async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "codex-backend-test-"));
    const projectPath = path.join(tempRoot, "demo-project");
    await writeFile(path.join(tempRoot, "placeholder.txt"), "");

    await mkdir(projectPath);
    await mkdir(path.join(projectPath, "lib"));
    await writeFile(
      path.join(projectPath, "package.json"),
      JSON.stringify({ name: "demo-project", version: "1.0.0" })
    );
    await writeFile(
      path.join(projectPath, "lib", "main.dart"),
      "void main() {\n  print('hello');\n}\n"
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

  it("returns the current model catalog including GPT-5.4", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/models",
      headers: { "x-api-token": token }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json() as {
      models: Array<{ id: string }>;
    };

    expect(body.models.map((model) => model.id)).toContain("gpt-5.4");
  });

  it("lists project files and reads file content", async () => {
    const projectResponse = await app.inject({
      method: "GET",
      url: "/projects",
      headers: { "x-api-token": token }
    });
    const projectId = expectDemoProject(
      (projectResponse.json() as {
        projects: Array<{ id: string; path: string }>;
      }).projects
    ).id;

    const listingResponse = await app.inject({
      method: "GET",
      url: `/projects/${projectId}/files`,
      headers: { "x-api-token": token }
    });

    expect(listingResponse.statusCode).toBe(200);
    const listingBody = listingResponse.json() as {
      currentPath: string;
      entries: Array<{ path: string; isDirectory: boolean }>;
    };
    expect(listingBody.currentPath).toBe("");
    expect(listingBody.entries).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ path: "lib", isDirectory: true }),
        expect.objectContaining({ path: "package.json", isDirectory: false })
      ])
    );

    const documentResponse = await app.inject({
      method: "GET",
      url: `/projects/${projectId}/files/content?path=lib/main.dart`,
      headers: { "x-api-token": token }
    });

    expect(documentResponse.statusCode).toBe(200);
    const documentBody = documentResponse.json() as {
      path: string;
      content: string | null;
      isBinary: boolean;
    };
    expect(documentBody.path).toBe("lib/main.dart");
    expect(documentBody.isBinary).toBe(false);
    expect(documentBody.content).toContain("print('hello');");
  });

  it("saves uploaded file changes and downloads the result", async () => {
    const projectResponse = await app.inject({
      method: "GET",
      url: "/projects",
      headers: { "x-api-token": token }
    });
    const body = projectResponse.json() as {
      projects: Array<{ id: string; path: string }>;
    };
    const project = expectDemoProject(body.projects);

    const saveResponse = await app.inject({
      method: "PUT",
      url: `/projects/${project.id}/files/content`,
      headers: { "x-api-token": token },
      payload: {
        path: "lib/main.dart",
        content: "void main() {\n  print('updated');\n}\n"
      }
    });

    expect(saveResponse.statusCode).toBe(200);
    expect(await readFile(path.join(project.path, "lib", "main.dart"), "utf8")).toContain(
      "updated"
    );

    const uploadResponse = await app.inject({
      method: "POST",
      url: `/projects/${project.id}/files/upload`,
      headers: { "x-api-token": token },
      payload: {
        directoryPath: "lib",
        fileName: "notes.txt",
        contentBase64: Buffer.from("download me\n", "utf8").toString("base64")
      }
    });

    expect(uploadResponse.statusCode).toBe(200);
    expect(await readFile(path.join(project.path, "lib", "notes.txt"), "utf8")).toBe(
      "download me\n"
    );

    const downloadResponse = await app.inject({
      method: "GET",
      url: `/projects/${project.id}/files/download?path=lib/notes.txt`,
      headers: { "x-api-token": token }
    });

    expect(downloadResponse.statusCode).toBe(200);
    expect(downloadResponse.headers["x-codex-file-name"]).toBe("notes.txt");
    expect(downloadResponse.body).toBe("download me\n");
  });

  it("creates terminal sessions and removes them cleanly after exit", async () => {
    const createResponse = await app.inject({
      method: "POST",
      url: "/terminal/sessions",
      headers: { "x-api-token": token },
      payload: {}
    });

    expect(createResponse.statusCode).toBe(200);
    const createBody = createResponse.json() as {
      session: { id: string; running: boolean };
    };
    const terminalId = createBody.session.id;
    expect(createBody.session.running).toBe(true);

    const exitResponse = await app.inject({
      method: "POST",
      url: `/terminal/sessions/${terminalId}/input`,
      headers: { "x-api-token": token },
      payload: { input: "exit\n" }
    });

    expect(exitResponse.statusCode).toBe(200);

    let running = true;
    for (let attempt = 0; attempt < 40; attempt += 1) {
      await delay(50);
      const snapshotResponse = await app.inject({
        method: "GET",
        url: `/terminal/sessions/${terminalId}`,
        headers: { "x-api-token": token }
      });

      expect(snapshotResponse.statusCode).toBe(200);
      const snapshotBody = snapshotResponse.json() as {
        session: { running: boolean };
      };
      running = snapshotBody.session.running;
      if (!running) {
        break;
      }
    }

    expect(running).toBe(false);

    const closeResponse = await app.inject({
      method: "DELETE",
      url: `/terminal/sessions/${terminalId}`,
      headers: { "x-api-token": token }
    });

    expect(closeResponse.statusCode).toBe(200);

    const listResponse = await app.inject({
      method: "GET",
      url: "/terminal/sessions",
      headers: { "x-api-token": token }
    });

    expect(listResponse.statusCode).toBe(200);
    const listBody = listResponse.json() as {
      sessions: Array<{ id: string }>;
    };
    expect(listBody.sessions.some((session) => session.id === terminalId)).toBe(
      false
    );
  });

  it("creates a session and streams assistant response", async () => {
    const projectResponse = await app.inject({
      method: "GET",
      url: "/projects",
      headers: { "x-api-token": token }
    });

    const projectBody = projectResponse.json() as {
      projects: Array<{ id: string; path: string }>;
    };

    expect(projectBody.projects.length).toBeGreaterThan(0);
    const project = expectDemoProject(projectBody.projects);

    const sessionResponse = await app.inject({
      method: "POST",
      url: "/sessions",
      headers: { "x-api-token": token },
      payload: {
        projectId: project.id,
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
