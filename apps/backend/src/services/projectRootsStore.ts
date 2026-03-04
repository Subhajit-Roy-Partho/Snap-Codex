import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

type ProjectRootsStorePayload = {
  roots: string[];
};

const normalizeRoots = (roots: string[]): string[] => {
  const deduped = new Set<string>();

  for (const root of roots) {
    const trimmed = root.trim();
    if (!trimmed) {
      continue;
    }

    deduped.add(path.resolve(trimmed));
  }

  return Array.from(deduped.values()).sort((a, b) => a.localeCompare(b));
};

export class ProjectRootsStore {
  constructor(private readonly filePath: string) {}

  async load(): Promise<string[]> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<ProjectRootsStorePayload>;
      const roots = Array.isArray(parsed.roots)
        ? parsed.roots.filter((entry): entry is string => typeof entry === "string")
        : [];
      return normalizeRoots(roots);
    } catch {
      return [];
    }
  }

  async save(roots: string[]): Promise<void> {
    const normalized = normalizeRoots(roots);
    await mkdir(path.dirname(this.filePath), { recursive: true });
    await writeFile(
      this.filePath,
      JSON.stringify({ roots: normalized }, null, 2),
      "utf8"
    );
  }
}
