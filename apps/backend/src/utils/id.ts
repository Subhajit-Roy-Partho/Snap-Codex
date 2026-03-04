import { createHash } from "node:crypto";

export const makeStableId = (value: string): string =>
  createHash("sha1").update(value).digest("hex").slice(0, 16);
