import { useCallback, useState } from "react";

// Read synchronously so the first render already shows the saved choices.
// Only explicitly listed options are stored; capture targets stay in memory.
export function readPreferences<T extends Record<string, boolean>>(
  key: string,
  defaults: T,
): T {
  try {
    const saved: unknown = JSON.parse(localStorage.getItem(key) ?? "null");
    const result = { ...defaults };
    if (saved && typeof saved === "object") {
      for (const name of Object.keys(defaults) as (keyof T)[]) {
        const value = (saved as Record<keyof T, unknown>)[name];
        if (typeof value === "boolean") result[name] = value as T[keyof T];
      }
    }
    return result;
  } catch {
    return { ...defaults };
  }
}

export function usePreferences<T extends Record<string, boolean>>(
  key: string,
  defaults: T,
): [T, (value: T) => void] {
  const [value, setValue] = useState(() => readPreferences(key, defaults));
  const save = useCallback((next: T) => {
    setValue(next);
    try {
      localStorage.setItem(key, JSON.stringify(next));
    } catch {
      // Keep settings usable if webview storage is unavailable.
    }
  }, [key]);
  return [value, save];
}
