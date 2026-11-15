import Icon from "@/components/ui/icons/icons";
import {
  Menu,
  MenuTrigger,
  MenuPopup,
  MenuItem,
  MenuSeparator,
  MenuGroup,
} from "@/components/ui/menu";
import { Button } from "@/components/ui/button";
import { api, native } from "@/lib/tauri";
import { getCurrentWindow } from "@tauri-apps/api/window";
export function ProjectMenu({
  hasProject,
  recordingView,
  recordingsFolderAvailable,
  disabled,
  run,
}: {
  hasProject: boolean;
  recordingView: boolean;
  recordingsFolderAvailable: boolean;
  disabled: boolean;
  run: (f: () => Promise<unknown>) => Promise<boolean>;
}) {
  return (
    <Menu>
      <MenuTrigger
        render={
          <Button variant="outline" size="icon-sm" aria-label="Project menu" />
        }
      >
        <Icon name="dotsVertical" />
      </MenuTrigger>
      <MenuPopup align="end" sideOffset={8} className="project-menu">
        <MenuGroup>
          <MenuItem
            disabled={disabled || recordingView}
            onClick={() => run(api.newRecording)}
          >
            <Icon name="plus" />
            New recording
          </MenuItem>
          <MenuItem
            disabled={disabled || !native}
            onClick={() => run(() => api.open())}
          >
            <Icon name="folder" />
            Open project…
          </MenuItem>
          {recordingView && (
            <MenuItem
              disabled={disabled || !native || !recordingsFolderAvailable}
              onClick={() => run(api.changeRecordingsFolder)}
            >
              <Icon name="folder" />
              Save location…
            </MenuItem>
          )}
        </MenuGroup>
        {hasProject && (
          <>
            <MenuSeparator />
            <MenuItem
              disabled={disabled}
              onClick={() => run(() => api.file("reveal"))}
            >
              <Icon name="folder" />
              Show project in Finder
            </MenuItem>
            <MenuItem
              disabled={disabled}
              onClick={() => run(() => api.file("copy-path"))}
            >
              <Icon name="copy" />
              Copy project path
            </MenuItem>
            <MenuItem disabled={disabled} onClick={() => run(api.save)}>
              <Icon name="save" />
              Save project
            </MenuItem>
            <MenuItem disabled={disabled} onClick={() => run(api.saveAs)}>
              <Icon name="copy" />
              Save As…
            </MenuItem>
            <MenuItem
              disabled={disabled}
              onClick={() => run(() => api.export(true))}
            >
              <Icon name="download" />
              Export web to…
            </MenuItem>
            <MenuItem
              disabled={disabled}
              onClick={() => run(() => api.export(true, "h264"))}
            >
              <Icon name="download" />
              Export MP4 to…
            </MenuItem>
          </>
        )}
        {native && (
          <>
            <MenuSeparator />
            <MenuItem onClick={() => getCurrentWindow().minimize()}>
              <Icon name="minus" />
              Minimize
            </MenuItem>
            <MenuItem
              disabled={disabled}
              onClick={() => getCurrentWindow().close()}
            >
              <Icon name="x" />
              Close Saturn
            </MenuItem>
          </>
        )}
      </MenuPopup>
    </Menu>
  );
}
