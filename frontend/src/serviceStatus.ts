export type ServiceStatus = "running" | "stopped";

type TauriInvoke = (command: string, args?: Record<string, unknown>) => Promise<unknown>;

const getTauriInvoke = (): TauriInvoke | null => {
  const tauri = (window as Window & { __TAURI__?: any }).__TAURI__;
  if (!tauri) return null;
  if (typeof tauri?.core?.invoke === "function") return tauri.core.invoke;
  if (typeof tauri?.invoke === "function") return tauri.invoke;
  return null;
};

const normalizeStatus = (value: unknown): ServiceStatus => {
  if (typeof value === "boolean") return value ? "running" : "stopped";
  if (typeof value === "string") {
    const normalized = value.toLowerCase();
    if (normalized === "running" || normalized === "stopped") return normalized;
  }
  return "stopped";
};

export const getServiceStatus = async (): Promise<ServiceStatus> => {
  const invoke = getTauriInvoke();
  if (invoke) {
    try {
      const result = await invoke("service_status");
      return normalizeStatus(result);
    } catch (error) {
      console.error("failed to get service status via tauri invoke", error);
    }
  }

  try {
    const response = await fetch("/admin/api/ping", { method: "GET" });
    const body = await response.text();
    if (response.ok && body.trim() === "pong") return "running";
    return "stopped";
  } catch (error) {
    console.error("failed to get service status via REST fallback", error);
    return "stopped";
  }
};
