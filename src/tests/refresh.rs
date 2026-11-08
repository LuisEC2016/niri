//! Tests for the per-iteration refresh bookkeeping (foreign toplevels, IPC, ext-workspace,
//! screencast window outputs).
//!
//! These skip their cleanup when nothing was removed. The debug assertions in those functions
//! check that no stale entries remain, so these tests mostly need to drive removals through them.

use client::ClientId;
use wayland_client::protocol::wl_surface::WlSurface;

use super::*;

fn map_window(f: &mut Fixture, id: ClientId) -> WlSurface {
    let window = f.client(id).create_window();
    let surface = window.surface.clone();
    window.commit();
    f.roundtrip(id);

    let window = f.client(id).window(&surface);
    window.attach_new_buffer();
    window.ack_last_and_commit();
    f.roundtrip(id);

    surface
}

fn unmap_window(f: &mut Fixture, id: ClientId, surface: &WlSurface) {
    let window = f.client(id).window(surface);
    window.attach_null();
    window.commit();
    f.double_roundtrip(id);
}

#[test]
fn unmapping_windows_and_removing_workspaces() {
    let mut f = Fixture::new();
    f.add_output(1, (1920, 1080));
    let id = f.add_client();

    let surfaces: Vec<_> = (0..4).map(|_| map_window(&mut f, id)).collect();
    f.double_roundtrip(id);

    // Spread the windows over more workspaces.
    f.niri().layout.move_to_workspace_down(true);
    f.double_roundtrip(id);
    f.niri().layout.switch_workspace_up();
    f.niri().layout.move_to_workspace_down(false);
    f.double_roundtrip(id);
    assert_eq!(f.niri().layout.windows().count(), 4);
    let workspaces = f.niri().layout.workspaces().count();

    // Unmap a window from the middle of the layout.
    unmap_window(&mut f, id, &surfaces[1]);
    assert_eq!(f.niri().layout.windows().count(), 3);

    // Unmap the rest. The workspaces that become empty go away once they are no longer active.
    for surface in [&surfaces[0], &surfaces[2], &surfaces[3]] {
        unmap_window(&mut f, id, surface);
    }
    f.niri().layout.switch_workspace(0);
    f.niri_complete_animations();
    f.double_roundtrip(id);
    assert_eq!(f.niri().layout.windows().count(), 0);
    assert!(f.niri().layout.workspaces().count() < workspaces);

    // Mapping again after everything was removed works.
    map_window(&mut f, id);
    f.double_roundtrip(id);
    assert_eq!(f.niri().layout.windows().count(), 1);
}
