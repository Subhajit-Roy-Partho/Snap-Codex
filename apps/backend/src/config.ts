import dotenv from "dotenv";

dotenv.config();

const parseList = (value: string | undefined, fallback: string[]): string[] => {
  if (!value) {
    return fallback;
  }

  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
};

export type AppConfig = {
  host: string;
  port: number;
  authToken: string;
  jwtSecret: string;
  allowedProjectRoots: string[];
  projectRootsStorePath: string;
  codexRuntime: "mock" | "app-server" | "cli";
  codexCommand: string;
  codexArgs: string[];
  modelCatalogOverride?: string;
  enablePush: boolean;
  firebaseServiceAccountJson?: string;
};

const parseRuntime = (
  value: string | undefined
): AppConfig["codexRuntime"] => {
  if (value === "mock" || value === "cli" || value === "app-server") {
    return value;
  }

  return "app-server";
};

export const config: AppConfig = {
  host: process.env.HOST ?? "0.0.0.0",
  port: Number(process.env.PORT ?? 8787),
  authToken: process.env.AUTH_TOKEN ?? "dev-token",
  jwtSecret: process.env.JWT_SECRET ?? "dev-jwt-secret",
  allowedProjectRoots: parseList(process.env.PROJECT_ROOTS, [process.cwd()]),
  projectRootsStorePath:
    process.env.PROJECT_ROOTS_STORE_PATH ??
    `${process.cwd()}/.codex/project-roots.json`,
  codexRuntime: parseRuntime(process.env.CODEX_RUNTIME),
  codexCommand: process.env.CODEX_COMMAND ?? "codex",
  codexArgs: parseList(process.env.CODEX_ARGS, ["app-server", "--listen", "stdio://"]),
  modelCatalogOverride: process.env.MODEL_CATALOG_JSON,
  enablePush: process.env.ENABLE_PUSH === "true",
  firebaseServiceAccountJson: process.env.FIREBASE_SERVICE_ACCOUNT_JSON
};
