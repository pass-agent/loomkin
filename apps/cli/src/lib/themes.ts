import pc from "picocolors";

/**
 * Semantic color tokens used throughout the TUI.
 * Each theme maps these tokens to terminal color functions.
 */
export interface Theme {
  name: string;
  label: string;
  description: string;
  colorblind: boolean;

  // Status indicators
  success: (s: string) => string;
  error: (s: string) => string;
  warning: (s: string) => string;
  info: (s: string) => string;

  // UI chrome
  accent: (s: string) => string;
  dim: (s: string) => string;
  bold: (s: string) => string;
  muted: (s: string) => string;

  // Agent status
  agentWorking: (s: string) => string;
  agentIdle: (s: string) => string;
  agentBlocked: (s: string) => string;
  agentError: (s: string) => string;

  // Roles
  roleName: (s: string) => string;
  userName: (s: string) => string;
  assistantName: (s: string) => string;
  toolName: (s: string) => string;

  // Borders
  borderColor: string;
  activeBorderColor: string;
}

// ── Default ─────────────────────────────────────────────────────────
export const defaultTheme: Theme = {
  name: "default",
  label: "Default",
  description: "Standard colors for dark terminals",
  colorblind: false,

  success: pc.green,
  error: pc.red,
  warning: pc.yellow,
  info: pc.cyan,

  accent: pc.cyan,
  dim: pc.dim,
  bold: pc.bold,
  muted: pc.gray,

  agentWorking: pc.green,
  agentIdle: pc.dim,
  agentBlocked: pc.yellow,
  agentError: pc.red,

  roleName: pc.cyan,
  userName: pc.blue,
  assistantName: pc.magenta,
  toolName: pc.yellow,

  borderColor: "gray",
  activeBorderColor: "cyan",
};

// ── High Contrast ───────────────────────────────────────────────────
// Uses bold + bright colors, avoids dim/gray. Good for low-vision users.
export const highContrastTheme: Theme = {
  name: "high-contrast",
  label: "High Contrast",
  description: "Bold, bright colors for low vision",
  colorblind: false,

  success: (s) => pc.bold(pc.green(s)),
  error: (s) => pc.bold(pc.red(s)),
  warning: (s) => pc.bold(pc.yellow(s)),
  info: (s) => pc.bold(pc.cyan(s)),

  accent: (s) => pc.bold(pc.white(s)),
  dim: pc.white,
  bold: pc.bold,
  muted: pc.white,

  agentWorking: (s) => pc.bold(pc.green(s)),
  agentIdle: pc.white,
  agentBlocked: (s) => pc.bold(pc.yellow(s)),
  agentError: (s) => pc.bold(pc.red(s)),

  roleName: (s) => pc.bold(pc.cyan(s)),
  userName: (s) => pc.bold(pc.blue(s)),
  assistantName: (s) => pc.bold(pc.magenta(s)),
  toolName: (s) => pc.bold(pc.yellow(s)),

  borderColor: "white",
  activeBorderColor: "white",
};

// ── Accessible (Red-Green Safe) ─────────────────────────────────────
// Most common colorblindness (~8% of males). Replaces red/green with
// blue/orange distinguishable pairs.
export const accessibleTheme: Theme = {
  name: "accessible",
  label: "Accessible (Recommended)",
  description: "Red-green safe — best for most colorblind users",
  colorblind: true,

  success: pc.blue,
  error: (s) => pc.bold(pc.yellow(s)),
  warning: pc.magenta,
  info: pc.cyan,

  accent: pc.cyan,
  dim: pc.dim,
  bold: pc.bold,
  muted: pc.gray,

  agentWorking: pc.blue,
  agentIdle: pc.dim,
  agentBlocked: pc.magenta,
  agentError: (s) => pc.bold(pc.yellow(s)),

  roleName: pc.cyan,
  userName: pc.blue,
  assistantName: pc.magenta,
  toolName: pc.cyan,

  borderColor: "gray",
  activeBorderColor: "cyan",
};

// ── Blue-Yellow Safe (Tritanopia) ───────────────────────────────────
// Rare (~0.01%). Replaces blue/yellow with red/cyan pairs.
export const blueYellowSafeTheme: Theme = {
  name: "blue-yellow-safe",
  label: "Blue-Yellow Safe",
  description: "For tritanopia — uses red/cyan pairs",
  colorblind: true,

  success: pc.green,
  error: pc.red,
  warning: pc.magenta,
  info: pc.green,

  accent: pc.green,
  dim: pc.dim,
  bold: pc.bold,
  muted: pc.gray,

  agentWorking: pc.green,
  agentIdle: pc.dim,
  agentBlocked: pc.magenta,
  agentError: pc.red,

  roleName: pc.green,
  userName: pc.red,
  assistantName: pc.magenta,
  toolName: pc.green,

  borderColor: "gray",
  activeBorderColor: "green",
};

// ── Monochrome ──────────────────────────────────────────────────────
// No color at all — uses bold, dim, underline, inverse for distinction.
// Universal accessibility.
export const monochromeTheme: Theme = {
  name: "monochrome",
  label: "Monochrome",
  description: "No color — bold, dim, and inverse only",
  colorblind: true,

  success: pc.bold,
  error: pc.inverse,
  warning: pc.underline,
  info: pc.bold,

  accent: pc.bold,
  dim: pc.dim,
  bold: pc.bold,
  muted: pc.dim,

  agentWorking: pc.bold,
  agentIdle: pc.dim,
  agentBlocked: pc.underline,
  agentError: pc.inverse,

  roleName: pc.bold,
  userName: pc.underline,
  assistantName: pc.bold,
  toolName: pc.dim,

  borderColor: "gray",
  activeBorderColor: "white",
};

// ── Loomkin (Brand) ─────────────────────────────────────────────────
// Matches the Phoenix web app and mobile app color palette.
// Web: Catppuccin pastels + brand purple (#b4a0e8)
// Mobile: Indigo/violet (#6366f1) + dark navy
// Terminal approximations using ANSI 16 colors.
export const loomkinTheme: Theme = {
  name: "loomkin",
  label: "Loomkin",
  description: "Brand purple — matches web and mobile",
  colorblind: false,

  // Catppuccin-inspired semantic colors
  success: pc.green,           // emerald #a6e3a1
  error: pc.red,               // rose #f38ba8
  warning: pc.yellow,          // amber #f9e2af
  info: pc.cyan,               // cyan #89dceb

  // Brand purple as accent
  accent: pc.magenta,          // mauve #cba6f7 / brand #b4a0e8
  dim: pc.dim,
  bold: pc.bold,
  muted: pc.gray,

  // Agent status — catppuccin pairs
  agentWorking: pc.green,      // emerald
  agentIdle: pc.dim,
  agentBlocked: pc.yellow,     // amber
  agentError: pc.red,          // rose

  // Roles — purple/cyan from the brand palette
  roleName: pc.cyan,           // cyan #89dceb
  userName: pc.magenta,        // mauve #cba6f7
  assistantName: pc.magenta,   // brand purple
  toolName: pc.yellow,         // peach #fab387

  borderColor: "magenta",
  activeBorderColor: "cyan",
};

// ── Registry ────────────────────────────────────────────────────────

export const themes: Record<string, Theme> = {
  accessible: accessibleTheme,
  loomkin: loomkinTheme,
  default: defaultTheme,
  "high-contrast": highContrastTheme,
  "blue-yellow-safe": blueYellowSafeTheme,
  monochrome: monochromeTheme,
};

export const themeList = Object.values(themes);

export function getTheme(name: string): Theme {
  return themes[name] || defaultTheme;
}
