import { getCurrentWindow } from "@tauri-apps/api/window";
import { native } from "@/lib/tauri";

// The modal blocks the app's title bar, so provide its drag surface in the
// modal viewport. Keep it behind the popup so dialog controls still work.
export function ModalDragRegion() {
  if (!native) return null;

  return (
    <div
      className="modal-drag-region"
      aria-hidden="true"
      onMouseDown={(event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        void getCurrentWindow().startDragging().catch(() => {});
      }}
    />
  );
}
