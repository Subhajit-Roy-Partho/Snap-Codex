import type {
  CollaborationModeOption,
  Model,
  PermissionProfile
} from "@codex/contracts";

const defaultModels: Model[] = [
  {
    id: "gpt-5-codex",
    displayName: "GPT-5 Codex",
    capabilities: ["tool-use", "code", "reasoning"],
    defaultProfileIds: ["xhigh", "yolo"],
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
    defaultReasoningEffort: "medium"
  },
  {
    id: "gpt-5-mini",
    displayName: "GPT-5 Mini",
    capabilities: ["chat", "code"],
    defaultProfileIds: ["xhigh"],
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
    defaultReasoningEffort: "medium"
  }
];

const defaultProfiles: PermissionProfile[] = [
  {
    id: "xhigh",
    name: "XHigh (Guarded)",
    codexFlags: [],
    guardrails: {
      blockDestructiveShell: true,
      requirePermissionPrompts: true
    }
  },
  {
    id: "yolo",
    name: "YOLO (Unrestricted)",
    codexFlags: [],
    guardrails: {
      blockDestructiveShell: false,
      requirePermissionPrompts: false
    }
  }
];

export const buildModelCatalog = (overrideJson?: string): Model[] => {
  if (!overrideJson) {
    return defaultModels;
  }

  try {
    const parsed = JSON.parse(overrideJson) as Model[];
    if (!Array.isArray(parsed) || parsed.length === 0) {
      return defaultModels;
    }
    return parsed;
  } catch {
    return defaultModels;
  }
};

export const buildProfileCatalog = (): PermissionProfile[] => defaultProfiles;

const defaultCollaborationModes: CollaborationModeOption[] = [
  {
    id: "default",
    name: "Default",
    description: "Execution-first mode for regular coding tasks."
  },
  {
    id: "plan",
    name: "Plan",
    description: "Plan-focused mode that returns structured proposed plans first."
  }
];

export const buildCollaborationModeCatalog = (): CollaborationModeOption[] =>
  defaultCollaborationModes;
