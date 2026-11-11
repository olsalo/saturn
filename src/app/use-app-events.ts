import { useEffect, useReducer, useState, useCallback } from "react";
import { api, native } from "@/lib/tauri";
import { initialSnapshot, recorderReducer } from "./recorder-machine";
export function useAppEvents() {
  const [state, dispatch] = useReducer(recorderReducer, initialSnapshot);
  const [working, setWorking] = useState(false);
  useEffect(() => {
    if (!native) return;
    let disposed = false;
    let unsubscribe: (() => void) | undefined;
    void api
      .subscribe((snapshot) => {
        if (!disposed) dispatch({ type: "backend", snapshot });
      })
      .then(async (stop) => {
        if (disposed) {
          stop();
          return;
        }
        unsubscribe = stop;
        const snapshot = await api.snapshot();
        if (!disposed) dispatch({ type: "backend", snapshot });
      })
      .catch((error) => {
        if (!disposed) dispatch({ type: "error", message: String(error) });
      });
    return () => {
      disposed = true;
      unsubscribe?.();
    };
  }, []);
  const run = useCallback(async (action: () => Promise<unknown>) => {
    setWorking(true);
    try {
      await action();
      return true;
    } catch (error) {
      dispatch({
        type: "error",
        message: error instanceof Error ? error.message : String(error),
      });
      return false;
    } finally {
      setWorking(false);
    }
  }, []);
  return {
    state,
    working,
    run,
    dismiss: () => {
      dispatch({ type: "clear-error" });
      if (native) void api.clearError();
    },
  };
}
