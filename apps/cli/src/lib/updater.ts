import Conf from "conf";

const PACKAGE_NAME = "@loomkin/cli";
const NPM_REGISTRY_URL = `https://registry.npmjs.org/${encodeURIComponent(PACKAGE_NAME)}/latest`;
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000; // 24 hours

interface UpdaterConf {
  lastCheckAt: number;
  availableVersion: string | null;
}

const updaterConf = new Conf<UpdaterConf>({
  projectName: "loomkin-updater",
  defaults: {
    lastCheckAt: 0,
    availableVersion: null,
  },
});

// In-memory available version (set after background check)
let _availableVersion: string | null = null;

/**
 * Compare semver strings. Returns true if b > a.
 */
function isNewer(current: string, latest: string): boolean {
  const parse = (v: string) =>
    v
      .replace(/^v/, "")
      .split(".")
      .map((n) => parseInt(n, 10) || 0);
  const [cMaj, cMin, cPatch] = parse(current);
  const [lMaj, lMin, lPatch] = parse(latest);
  if (lMaj !== cMaj) return lMaj > cMaj;
  if (lMin !== cMin) return lMin > cMin;
  return lPatch > cPatch;
}

/**
 * Fire-and-forget update check. Never blocks startup.
 * Throttled to once per 24h. Respects NO_UPDATE_CHECK=1.
 */
export function checkForUpdate(currentVersion: string): void {
  // Opt-out via env var
  if (process.env.NO_UPDATE_CHECK === "1") return;

  // Check throttle
  const lastCheck = updaterConf.get("lastCheckAt");
  if (Date.now() - lastCheck < CHECK_INTERVAL_MS) {
    // Restore previously cached available version into memory
    const cached = updaterConf.get("availableVersion");
    if (cached && isNewer(currentVersion, cached)) {
      _availableVersion = cached;
    }
    return;
  }

  // Async fetch — fire and forget
  (async () => {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000);
      const res = await fetch(NPM_REGISTRY_URL, {
        signal: controller.signal,
        headers: { Accept: "application/json" },
      });
      clearTimeout(timer);
      if (!res.ok) return;
      const data = (await res.json()) as { version?: string };
      const latest = data.version;
      if (!latest) return;

      updaterConf.set("lastCheckAt", Date.now());

      if (isNewer(currentVersion, latest)) {
        _availableVersion = latest;
        updaterConf.set("availableVersion", latest);
      } else {
        updaterConf.set("availableVersion", null);
      }
    } catch {
      // Network errors are silently ignored
    }
  })().catch(() => {});
}

/**
 * Returns the newer version string if an update is available, or null.
 */
export function getUpdateAvailable(): string | null {
  return _availableVersion;
}
