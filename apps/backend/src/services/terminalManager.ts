import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { constants as fsConstants } from "node:fs";
import { access, stat } from "node:fs/promises";
import path from "node:path";

export type TerminalSession = {
  id: string;
  cwd: string;
  shell: string;
  running: boolean;
  startedAt: string;
  endedAt: string | null;
};

export type TerminalSnapshot = {
  session: TerminalSession;
  output: string;
};

export type TerminalManagerEvent =
  | {
      type: "terminal.started";
      payload: {
        terminalId: string;
        cwd: string;
        shell: string;
        running: boolean;
        startedAt: string;
      };
    }
  | {
      type: "terminal.output";
      payload: {
        terminalId: string;
        stream: "stdout" | "stderr";
        data: string;
        timestamp: string;
      };
    }
  | {
      type: "terminal.exited";
      payload: {
        terminalId: string;
        exitCode: number | null;
        signal: string | null;
        timestamp: string;
      };
    };

type CreateTerminalSessionInput = {
  cwd?: string;
  shell?: string;
  bootstrap?: string[];
  cols?: number;
  rows?: number;
};

type TerminalEntry = {
  session: TerminalSession;
  process: ChildProcessWithoutNullStreams;
  outputBuffer: string;
};

const MAX_TERMINAL_OUTPUT_BUFFER = 400_000;
const MIN_COLS = 20;
const MAX_COLS = 400;
const MIN_ROWS = 5;
const MAX_ROWS = 200;

const trimOutputBuffer = (value: string): string => {
  if (value.length <= MAX_TERMINAL_OUTPUT_BUFFER) {
    return value;
  }

  return value.slice(value.length - MAX_TERMINAL_OUTPUT_BUFFER);
};

const clamp = (value: number, min: number, max: number): number =>
  Math.min(max, Math.max(min, value));

const resolveCwd = (value?: string): string => {
  const raw = value?.trim();
  if (!raw) {
    return process.cwd();
  }

  if (path.isAbsolute(raw)) {
    return path.resolve(raw);
  }

  return path.resolve(process.cwd(), raw);
};

const normalizeBootstrapCommands = (value?: string[]): string[] => {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map((entry) => `${entry}`.trim())
    .filter((entry) => entry.length > 0);
};

const resolveShellCommand = (): string => {
  const configured = process.env.SHELL?.trim();
  if (configured && configured.length > 0) {
    return configured;
  }
  return "/bin/zsh";
};

export class TerminalManager {
  private readonly sessions = new Map<string, TerminalEntry>();
  private readonly eventBus = new EventEmitter();

  onEvent(handler: (event: TerminalManagerEvent) => void): () => void {
    this.eventBus.on("terminal-event", handler);
    return () => this.eventBus.off("terminal-event", handler);
  }

  listSessions(): TerminalSession[] {
    return Array.from(this.sessions.values())
      .map((entry) => ({ ...entry.session }))
      .sort((a, b) => a.startedAt.localeCompare(b.startedAt));
  }

  getSnapshot(terminalId: string): TerminalSnapshot {
    const entry = this.sessions.get(terminalId);
    if (!entry) {
      throw new Error("Terminal session not found");
    }

    return {
      session: { ...entry.session },
      output: entry.outputBuffer
    };
  }

  async createSession(input: CreateTerminalSessionInput): Promise<TerminalSnapshot> {
    const resolvedCwd = resolveCwd(input.cwd);
    await this.validateCwd(resolvedCwd);

    const shell = input.shell?.trim() || resolveShellCommand();
    const shellWithInteractiveFlag = shell.includes("zsh")
      ? `${shell} -i`
      : `${shell} -il`;
    const childProcess = spawn("script", ["-qf", "/dev/null", "-c", shellWithInteractiveFlag], {
      cwd: resolvedCwd,
      env: {
        ...process.env,
        TERM: process.env.TERM ?? "xterm-256color"
      },
      stdio: "pipe"
    });

    const session: TerminalSession = {
      id: randomUUID(),
      cwd: resolvedCwd,
      shell,
      running: true,
      startedAt: new Date().toISOString(),
      endedAt: null
    };

    const entry: TerminalEntry = {
      session,
      process: childProcess,
      outputBuffer: ""
    };
    this.sessions.set(session.id, entry);

    this.emitEvent({
      type: "terminal.started",
      payload: {
        terminalId: session.id,
        cwd: session.cwd,
        shell: session.shell,
        running: session.running,
        startedAt: session.startedAt
      }
    });

    childProcess.stdout.on("data", (chunk: Buffer | string) => {
      this.handleOutput(entry, "stdout", chunk);
    });
    childProcess.stderr.on("data", (chunk: Buffer | string) => {
      this.handleOutput(entry, "stderr", chunk);
    });
    childProcess.on("close", (exitCode: number | null, signal: NodeJS.Signals | null) => {
      entry.session.running = false;
      entry.session.endedAt = new Date().toISOString();
      this.emitEvent({
        type: "terminal.exited",
        payload: {
          terminalId: entry.session.id,
          exitCode: typeof exitCode === "number" ? exitCode : null,
          signal: signal ?? null,
          timestamp: new Date().toISOString()
        }
      });
    });
    childProcess.on("error", (error: Error) => {
      const message = `[terminal error] ${error.message}\n`;
      this.handleOutput(entry, "stderr", message);
    });

    this.resizeSession(session.id, {
      cols: clamp(input.cols ?? 120, MIN_COLS, MAX_COLS),
      rows: clamp(input.rows ?? 32, MIN_ROWS, MAX_ROWS)
    });

    for (const command of normalizeBootstrapCommands(input.bootstrap)) {
      this.writeInput(session.id, command.endsWith("\n") ? command : `${command}\n`);
    }

    return {
      session: { ...session },
      output: ""
    };
  }

  writeInput(terminalId: string, input: string): void {
    const entry = this.sessions.get(terminalId);
    if (!entry) {
      throw new Error("Terminal session not found");
    }
    if (
      !entry.session.running ||
      entry.process.exitCode !== null ||
      entry.process.stdin.destroyed
    ) {
      entry.session.running = false;
      if (entry.session.endedAt === null) {
        entry.session.endedAt = new Date().toISOString();
      }
      throw new Error("Terminal session is not running");
    }

    if (!input) {
      return;
    }

    entry.process.stdin.write(input);
  }

  resizeSession(terminalId: string, input: { cols: number; rows: number }): void {
    const entry = this.sessions.get(terminalId);
    if (!entry) {
      throw new Error("Terminal session not found");
    }

    const cols = clamp(input.cols, MIN_COLS, MAX_COLS);
    const rows = clamp(input.rows, MIN_ROWS, MAX_ROWS);
    const command = `stty cols ${cols} rows ${rows}\n`;
    if (!entry.process.stdin.destroyed) {
      entry.process.stdin.write(command);
    }
  }

  closeSession(terminalId: string): void {
    const entry = this.sessions.get(terminalId);
    if (!entry) {
      return;
    }

    if (entry.session.running) {
      entry.process.kill("SIGTERM");
    }
  }

  shutdown(): void {
    for (const entry of this.sessions.values()) {
      if (entry.session.running) {
        entry.process.kill("SIGTERM");
      }
    }
  }

  private async validateCwd(cwd: string): Promise<void> {
    let stats;
    try {
      stats = await stat(cwd);
    } catch {
      throw new Error(`Directory does not exist: ${cwd}`);
    }

    if (!stats.isDirectory()) {
      throw new Error(`Path is not a directory: ${cwd}`);
    }

    try {
      await access(cwd, fsConstants.R_OK | fsConstants.X_OK);
    } catch {
      throw new Error(`Directory is not accessible: ${cwd}`);
    }
  }

  private handleOutput(
    entry: TerminalEntry,
    stream: "stdout" | "stderr",
    chunk: Buffer | string
  ): void {
    const text = typeof chunk === "string" ? chunk : chunk.toString("utf8");
    if (text.length === 0) {
      return;
    }

    entry.outputBuffer = trimOutputBuffer(`${entry.outputBuffer}${text}`);

    this.emitEvent({
      type: "terminal.output",
      payload: {
        terminalId: entry.session.id,
        stream,
        data: text,
        timestamp: new Date().toISOString()
      }
    });
  }

  private emitEvent(event: TerminalManagerEvent): void {
    this.eventBus.emit("terminal-event", event);
  }
}
