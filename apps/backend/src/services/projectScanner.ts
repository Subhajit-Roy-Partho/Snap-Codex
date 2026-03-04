import { access, readdir } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { Project } from "@codex/contracts";
import { makeStableId } from "../utils/id.js";

const execFileAsync = promisify(execFile);

const IGNORED_DIR_NAMES = new Set([
  "node_modules",
  ".git",
  ".next",
  "build",
  "dist",
  "target",
  ".dart_tool"
]);
const DEFAULT_MAX_SCAN_DEPTH = 3;

const isProjectDirectory = async (projectPath: string): Promise<boolean> => {
  const candidateFiles = ["package.json", "pubspec.yaml", "pyproject.toml", ".git"];

  for (const candidate of candidateFiles) {
    try {
      await access(path.join(projectPath, candidate));
      return true;
    } catch {
      // Keep scanning.
    }
  }

  return false;
};

const getGitBranch = async (projectPath: string): Promise<string | null> => {
  try {
    const { stdout } = await execFileAsync("git", [
      "-C",
      projectPath,
      "rev-parse",
      "--abbrev-ref",
      "HEAD"
    ]);
    const branch = stdout.trim();
    return branch.length > 0 ? branch : null;
  } catch {
    return null;
  }
};

const getGitDirty = async (projectPath: string): Promise<boolean> => {
  try {
    await execFileAsync("git", ["-C", projectPath, "diff", "--quiet"]);
    return false;
  } catch {
    return true;
  }
};

const toProject = async (projectPath: string): Promise<Project> => {
  const gitBranch = await getGitBranch(projectPath);
  const gitDirty = gitBranch ? await getGitDirty(projectPath) : false;

  return {
    id: makeStableId(projectPath),
    name: path.basename(projectPath),
    path: projectPath,
    gitBranch,
    gitDirty,
    lastSeenAt: new Date().toISOString()
  };
};

export class ProjectScanner {
  private roots: string[];

  constructor(initialRoots: string[], private readonly maxScanDepth = DEFAULT_MAX_SCAN_DEPTH) {
    this.roots = this.normalizeRoots(initialRoots);
  }

  getRoots(): string[] {
    return [...this.roots];
  }

  addRoot(root: string): boolean {
    const normalized = path.resolve(root);
    if (this.roots.includes(normalized)) {
      return false;
    }

    this.roots = this.normalizeRoots([...this.roots, normalized]);
    return true;
  }

  private normalizeRoots(roots: string[]): string[] {
    const unique = new Set<string>();
    roots
      .map((root) => root.trim())
      .filter((root) => root.length > 0)
      .forEach((root) => unique.add(path.resolve(root)));

    return Array.from(unique.values()).sort((a, b) => a.localeCompare(b));
  }

  async scan(): Promise<Project[]> {
    const foundPaths = new Set<string>();
    for (const root of this.roots) {
      const normalizedRoot = path.resolve(root);
      await this.collectProjectsRecursive(normalizedRoot, 0, foundPaths);
    }

    const projects = await Promise.all(
      Array.from(foundPaths.values())
        .sort((a, b) => a.localeCompare(b))
        .map((projectPath) => toProject(projectPath))
    );

    return projects;
  }

  private async collectProjectsRecursive(
    currentPath: string,
    depth: number,
    foundPaths: Set<string>
  ): Promise<void> {
    const normalizedCurrentPath = path.resolve(currentPath);
    const isRoot = depth === 0;
    const currentIsProject = isRoot
      ? false
      : await isProjectDirectory(normalizedCurrentPath);

    // Roots should always appear as selectable projects in the UI.
    if (isRoot || currentIsProject) {
      foundPaths.add(normalizedCurrentPath);
    }

    // Avoid deep traversal under detected project directories.
    if (currentIsProject) {
      return;
    }

    if (depth >= this.maxScanDepth) {
      return;
    }

    let entries;
    try {
      entries = await readdir(normalizedCurrentPath, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (!entry.isDirectory() || IGNORED_DIR_NAMES.has(entry.name)) {
        continue;
      }

      const nextPath = path.join(normalizedCurrentPath, entry.name);
      await this.collectProjectsRecursive(nextPath, depth + 1, foundPaths);
    }
  }
}
