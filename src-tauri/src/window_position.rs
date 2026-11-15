use serde::{Deserialize, Serialize};
use std::{fs, path::Path};
use tauri::{LogicalPosition, LogicalSize, WebviewWindow, WindowEvent};

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SavedPosition {
    x: i32,
    y: i32,
    // Older files only contain physical x/y. Infer their scale from the target
    // display once; new saves carry the scale so display changes are unambiguous.
    #[serde(default)]
    scale_factor: Option<f64>,
}

struct WorkArea {
    position: LogicalPosition<f64>,
    size: LogicalSize<f64>,
    scale_factor: f64,
}

impl WorkArea {
    fn contains(&self, position: LogicalPosition<f64>) -> bool {
        position.x >= self.position.x
            && position.y >= self.position.y
            && position.x < self.position.x + self.size.width
            && position.y < self.position.y + self.size.height
    }
}

fn placement(
    saved: Option<SavedPosition>,
    size: LogicalSize<f64>,
    areas: &[WorkArea],
    preferred: usize,
) -> (LogicalPosition<f64>, LogicalSize<f64>) {
    let restored = saved.and_then(|saved| {
        areas.iter().find_map(|area| {
            let scale = saved.scale_factor.unwrap_or(area.scale_factor);
            if !scale.is_finite() || scale <= 0.0 {
                return None;
            }
            let position = LogicalPosition::new(saved.x as f64 / scale, saved.y as f64 / scale);
            area.contains(position).then_some((area, position))
        })
    });
    let area = restored.map_or(&areas[preferred], |(area, _)| area);
    let size = LogicalSize::new(
        size.width.min(area.size.width),
        size.height.min(area.size.height),
    );
    let position = restored.map_or_else(
        || {
            LogicalPosition::new(
                area.position.x + (area.size.width - size.width) / 2.0,
                area.position.y + (area.size.height - size.height) / 2.0,
            )
        },
        |(_, position)| {
            LogicalPosition::new(
                position.x.clamp(
                    area.position.x,
                    area.position.x + area.size.width - size.width,
                ),
                position.y.clamp(
                    area.position.y,
                    area.position.y + area.size.height - size.height,
                ),
            )
        },
    );
    (position, size)
}

pub fn restore_and_track(window: &WebviewWindow, root: &Path) -> tauri::Result<()> {
    let path = root.join("window-position.json");
    let saved = fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<SavedPosition>(&bytes).ok());
    let monitors = window.available_monitors()?;
    let primary = window.primary_monitor()?;
    let preferred = monitors
        .iter()
        .position(|monitor| {
            primary.as_ref().is_some_and(|primary| {
                primary.position() == monitor.position() && primary.size() == monitor.size()
            })
        })
        .unwrap_or(0);
    let areas: Vec<_> = monitors
        .iter()
        .map(|monitor| {
            let scale = monitor.scale_factor();
            WorkArea {
                position: monitor.work_area().position.to_logical(scale),
                size: monitor.work_area().size.to_logical(scale),
                scale_factor: scale,
            }
        })
        .collect();
    if !areas.is_empty() {
        let current_size = window.outer_size()?.to_logical(window.scale_factor()?);
        let (position, size) = placement(saved, current_size, &areas, preferred);
        if size != current_size {
            window.set_min_size(Some(LogicalSize::new(
                400.0_f64.min(size.width),
                400.0_f64.min(size.height),
            )))?;
            window.set_size(size)?;
        }
        // Logical coordinates avoid interpreting a saved external-display position
        // using the scale of the display where the hidden window was created.
        window.set_position(position)?;
    } else {
        window.center()?;
    }
    // Stay hidden until React has hydrated and laid out the initial screen.
    let tracked = window.clone();
    window.on_window_event(move |event| {
        if let WindowEvent::Moved(_) = event {
            if let (Ok(position), Ok(scale_factor)) =
                (tracked.outer_position(), tracked.scale_factor())
            {
                let saved = SavedPosition {
                    x: position.x,
                    y: position.y,
                    scale_factor: Some(scale_factor),
                };
                if let Ok(bytes) = serde_json::to_vec(&saved) {
                    // Replace atomically so an interrupted write can't lose the last position.
                    let pending = path.with_extension("tmp");
                    if fs::write(&pending, bytes).is_ok() {
                        let _ = fs::rename(pending, &path);
                    }
                }
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn area(x: f64, y: f64, width: f64, height: f64, scale: f64) -> WorkArea {
        WorkArea {
            position: LogicalPosition::new(x, y),
            size: LogicalSize::new(width, height),
            scale_factor: scale,
        }
    }

    #[test]
    fn restores_external_display_position_independently_of_startup_scale() {
        let areas = [
            area(0.0, 25.0, 1440.0, 875.0, 2.0),
            area(-1920.0, 25.0, 1920.0, 1055.0, 1.0),
        ];
        let saved = SavedPosition {
            x: -1902,
            y: 270,
            scale_factor: Some(1.0),
        };
        let (position, size) = placement(Some(saved), LogicalSize::new(420.0, 800.0), &areas, 0);
        assert_eq!(position, LogicalPosition::new(-1902.0, 270.0));
        assert_eq!(size, LogicalSize::new(420.0, 800.0));
    }

    #[test]
    fn reads_legacy_physical_positions_on_a_retina_display() {
        let saved: SavedPosition = serde_json::from_str(r#"{"x":-3200,"y":200}"#).unwrap();
        let areas = [
            area(0.0, 25.0, 1440.0, 875.0, 1.0),
            area(-1920.0, 25.0, 1920.0, 1055.0, 2.0),
        ];
        let (position, _) = placement(Some(saved), LogicalSize::new(420.0, 800.0), &areas, 0);
        assert_eq!(position, LogicalPosition::new(-1600.0, 100.0));
    }

    #[test]
    fn clamps_restored_position_inside_the_work_area() {
        let areas = [area(0.0, 25.0, 1440.0, 875.0, 2.0)];
        let saved = SavedPosition {
            x: 2800,
            y: 1700,
            scale_factor: Some(2.0),
        };
        let (position, _) = placement(Some(saved), LogicalSize::new(420.0, 800.0), &areas, 0);
        assert_eq!(position, LogicalPosition::new(1020.0, 100.0));
    }

    #[test]
    fn fits_the_panel_on_a_display_shorter_than_the_default_height() {
        let areas = [area(0.0, 32.0, 1280.0, 720.0, 2.0)];
        let (position, size) = placement(None, LogicalSize::new(420.0, 800.0), &areas, 0);
        assert_eq!(size, LogicalSize::new(420.0, 720.0));
        assert_eq!(position, LogicalPosition::new(430.0, 32.0));
    }

    #[test]
    fn centers_on_primary_when_saved_display_is_disconnected_or_invalid() {
        let areas = [
            area(-1920.0, 25.0, 1920.0, 1055.0, 1.0),
            area(0.0, 25.0, 1440.0, 875.0, 2.0),
        ];
        for saved in [
            SavedPosition {
                x: -4000,
                y: 200,
                scale_factor: Some(1.0),
            },
            SavedPosition {
                x: i32::MAX,
                y: i32::MAX,
                scale_factor: None,
            },
            SavedPosition {
                x: 100,
                y: 100,
                scale_factor: Some(0.0),
            },
        ] {
            let (position, _) = placement(Some(saved), LogicalSize::new(420.0, 800.0), &areas, 1);
            assert_eq!(position, LogicalPosition::new(510.0, 62.5));
        }
    }

    #[test]
    fn uses_recorded_scale_after_a_display_scale_change() {
        let areas = [area(0.0, 25.0, 1920.0, 1055.0, 1.0)];
        let saved = SavedPosition {
            x: 400,
            y: 200,
            scale_factor: Some(2.0),
        };
        let (position, _) = placement(Some(saved), LogicalSize::new(420.0, 800.0), &areas, 0);
        assert_eq!(position, LogicalPosition::new(200.0, 100.0));
    }
}
