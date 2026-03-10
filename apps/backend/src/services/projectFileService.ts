import { constants as fsConstants } from "node:fs";
import {
  access,
  mkdir,
  open,
  readFile,
  readdir,
  stat,
  writeFile
} from "node:fs/promises";
import path from "node:path";
import type { Project } from "@codex/contracts";

const MAX_EDITABLE_TEXT_BYTES = 1024 * 1024;
const SAMPLE_BYTES = 4096;

type ProjectFilePathInfo = {
  project: Project;
  resolvedPath: string;
  relativePath: string;
};

export type ProjectFileEntry = {
  name: string;
  path: string;
  isDirectory: boolean;
  extension: string | null;
  sizeBytes: number | null;
  lastModifiedAt: string | null;
  readable: boolean;
  writable: boolean;
};

export type ProjectFileListing = {
  projectId: string;
  projectPath: string;
  currentPath: string;
  parentPath: string | null;
  entries: ProjectFileEntry[];
};

export type ProjectFileDocument = {
  projectId: string;
  projectPath: string;
  path: string;
  name: string;
  extension: string | null;
  sizeBytes: number;
  lastModifiedAt: string;
  readable: boolean;
  writable: boolean;
  isBinary: boolean;
  tooLarge: boolean;
  content: string | null;
};

export type ProjectFileDownload = {
  fileName: string;
  contentType: string;
  data: Buffer;
};

const normalizeRelativePath = (value: string): string => value.split(path.sep).join("/");

const extensionForPath = (filePath: string): string | null => {
  const extension = path.extname(filePath).trim().toLowerCase();
  return extension.length > 0 ? extension : null;
};

const contentTypeForExtension = (extension: string | null): string => {
  switch (extension) {
    case ".dart":
      return "application/dart";
    case ".js":
    case ".mjs":
    case ".cjs":
      return "text/javascript; charset=utf-8";
    case ".ts":
    case ".tsx":
      return "text/typescript; charset=utf-8";
    case ".json":
      return "application/json; charset=utf-8";
    case ".md":
      return "text/markdown; charset=utf-8";
    case ".html":
      return "text/html; charset=utf-8";
    case ".css":
      return "text/css; charset=utf-8";
    case ".yml":
    case ".yaml":
      return "application/yaml; charset=utf-8";
    case ".xml":
      return "application/xml; charset=utf-8";
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".svg":
      return "image/svg+xml";
    case ".pdf":
      return "application/pdf";
    default:
      return "application/octet-stream";
  }
};

const bufferLooksBinary = (value: Buffer): boolean => {
  if (value.includes(0)) {
    return true;
  }

  try {
    new TextDecoder("utf-8", { fatal: true }).decode(value);
    return false;
  } catch {
    return true;
  }
};

const safeFileName = (value: string): string => {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new Error("File name is required.");
  }

  if (
    trimmed === "." ||
    trimmed === ".." ||
    trimmed.includes("/") ||
    trimmed.includes("\\")
  ) {
    throw new Error("File name must not contain path separators.");
  }

  return trimmed;
};

export class ProjectFileService {
  constructor(private readonly getProjects: () => Project[]) {}

  private getProject(projectId: string): Project {
    const project = this.getProjects().find((entry) => entry.id === projectId);
    if (!project) {
      throw new Error("Project not found.");
    }

    return project;
  }

  private resolveProjectPath(projectId: string, inputPath: string): ProjectFilePathInfo {
    const project = this.getProject(projectId);
    const trimmed = inputPath.trim();
    const candidatePath =
      trimmed.length === 0
        ? project.path
        : path.isAbsolute(trimmed)
          ? trimmed
          : path.join(project.path, trimmed);
    const resolvedPath = path.resolve(candidatePath);
    const relativePath = path.relative(project.path, resolvedPath);

    if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
      throw new Error("Path must remain inside the selected project.");
    }

    return {
      project,
      resolvedPath,
      relativePath: relativePath.length === 0 ? "" : normalizeRelativePath(relativePath)
    };
  }

  private async canAccess(
    filePath: string,
    mode: number
  ): Promise<boolean> {
    try {
      await access(filePath, mode);
      return true;
    } catch {
      return false;
    }
  }

  private async readSample(resolvedPath: string, sizeBytes: number): Promise<Buffer> {
    const sampleSize = Math.min(sizeBytes, SAMPLE_BYTES);
    if (sampleSize <= 0) {
      return Buffer.alloc(0);
    }

    const handle = await open(resolvedPath, "r");
    try {
      const buffer = Buffer.alloc(sampleSize);
      const { bytesRead } = await handle.read(buffer, 0, sampleSize, 0);
      return buffer.subarray(0, bytesRead);
    } finally {
      await handle.close();
    }
  }

  async listDirectory(
    projectId: string,
    inputPath: string,
    limit = 400
  ): Promise<ProjectFileListing> {
    const { project, resolvedPath, relativePath } = this.resolveProjectPath(projectId, inputPath);

    const metadata = await stat(resolvedPath).catch(() => null);
    if (!metadata) {
      throw new Error("Directory does not exist.");
    }
    if (!metadata.isDirectory()) {
      throw new Error("Path must point to a directory.");
    }

    const entries = await readdir(resolvedPath, { withFileTypes: true }).catch(() => null);
    if (!entries) {
      throw new Error("Directory is not readable.");
    }

    const normalizedLimit = Math.max(1, Math.min(Math.floor(limit), 800));
    const entryDetails = await Promise.all(
      entries.slice(0, normalizedLimit).map(async (entry) => {
        const entryPath = path.join(resolvedPath, entry.name);
        const [entryStat, readable, writable] = await Promise.all([
          stat(entryPath).catch(() => null),
          this.canAccess(entryPath, fsConstants.R_OK),
          this.canAccess(
            entryPath,
            entry.isDirectory() ? fsConstants.W_OK | fsConstants.X_OK : fsConstants.W_OK
          )
        ]);

        return {
          name: entry.name,
          path: normalizeRelativePath(path.relative(project.path, entryPath)),
          isDirectory: entry.isDirectory(),
          extension: entry.isDirectory() ? null : extensionForPath(entry.name),
          sizeBytes:
            entry.isDirectory() || !entryStat ? null : entryStat.size,
          lastModifiedAt: entryStat ? entryStat.mtime.toISOString() : null,
          readable,
          writable
        } satisfies ProjectFileEntry;
      })
    );

    entryDetails.sort((left, right) => {
      if (left.isDirectory != right.isDirectory) {
        return left.isDirectory ? -1 : 1;
      }
      return left.name.localeCompare(right.name);
    });

    const parentPath =
      relativePath.length === 0
        ? null
        : normalizeRelativePath(path.dirname(relativePath));

    return {
      projectId: project.id,
      projectPath: project.path,
      currentPath: relativePath,
      parentPath: parentPath === "." ? "" : parentPath,
      entries: entryDetails
    };
  }

  async readDocument(
    projectId: string,
    inputPath: string
  ): Promise<ProjectFileDocument> {
    const { project, resolvedPath, relativePath } = this.resolveProjectPath(projectId, inputPath);
    const metadata = await stat(resolvedPath).catch(() => null);
    if (!metadata) {
      throw new Error("File does not exist.");
    }
    if (!metadata.isFile()) {
      throw new Error("Path must point to a file.");
    }

    const [readable, writable, sample] = await Promise.all([
      this.canAccess(resolvedPath, fsConstants.R_OK),
      this.canAccess(resolvedPath, fsConstants.W_OK),
      this.readSample(resolvedPath, metadata.size)
    ]);

    if (!readable) {
      throw new Error("File is not readable.");
    }

    const isBinary = bufferLooksBinary(sample);
    const tooLarge = !isBinary && metadata.size > MAX_EDITABLE_TEXT_BYTES;
    const content =
      isBinary || tooLarge ? null : await readFile(resolvedPath, "utf8");

    return {
      projectId: project.id,
      projectPath: project.path,
      path: relativePath,
      name: path.basename(resolvedPath),
      extension: extensionForPath(resolvedPath),
      sizeBytes: metadata.size,
      lastModifiedAt: metadata.mtime.toISOString(),
      readable,
      writable,
      isBinary,
      tooLarge,
      content
    };
  }

  async writeDocument(
    projectId: string,
    inputPath: string,
    content: string
  ): Promise<ProjectFileDocument> {
    const { resolvedPath } = this.resolveProjectPath(projectId, inputPath);
    const existingStat = await stat(resolvedPath).catch(() => null);
    if (existingStat?.isDirectory()) {
      throw new Error("Cannot overwrite a directory.");
    }

    await mkdir(path.dirname(resolvedPath), { recursive: true });
    await writeFile(resolvedPath, content, "utf8");

    return this.readDocument(projectId, inputPath);
  }

  async uploadFile(
    projectId: string,
    directoryPath: string,
    fileName: string,
    contentBase64: string
  ): Promise<ProjectFileEntry> {
    const safeName = safeFileName(fileName);
    const { project, resolvedPath } = this.resolveProjectPath(projectId, directoryPath);

    await mkdir(resolvedPath, { recursive: true });
    const targetPath = path.join(resolvedPath, safeName);
    const relativePath = normalizeRelativePath(path.relative(project.path, targetPath));
    if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
      throw new Error("Upload target must remain inside the selected project.");
    }

    const buffer = Buffer.from(contentBase64, "base64");
    await writeFile(targetPath, buffer);

    const [metadata, readable, writable] = await Promise.all([
      stat(targetPath),
      this.canAccess(targetPath, fsConstants.R_OK),
      this.canAccess(targetPath, fsConstants.W_OK)
    ]);

    return {
      name: safeName,
      path: relativePath,
      isDirectory: false,
      extension: extensionForPath(safeName),
      sizeBytes: metadata.size,
      lastModifiedAt: metadata.mtime.toISOString(),
      readable,
      writable
    };
  }

  async downloadFile(
    projectId: string,
    inputPath: string
  ): Promise<ProjectFileDownload> {
    const { resolvedPath } = this.resolveProjectPath(projectId, inputPath);
    const metadata = await stat(resolvedPath).catch(() => null);
    if (!metadata) {
      throw new Error("File does not exist.");
    }
    if (!metadata.isFile()) {
      throw new Error("Path must point to a file.");
    }

    const data = await readFile(resolvedPath);
    return {
      fileName: path.basename(resolvedPath),
      contentType: contentTypeForExtension(extensionForPath(resolvedPath)),
      data
    };
  }
}
