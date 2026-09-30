//! Phase-one capture probe. Disk output requires --capture-preview explicitly.
//! No upload, desktop fallback, focus or restore operation.
use super::identity;
use crate::{Identity, Snapshot};
use serde::Serialize;
use std::{
    path::Path,
    process::ExitCode,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use windows::{
    core::{factory, Interface},
    Graphics::{
        Capture::{
            Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureItem,
            GraphicsCaptureSession,
        },
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
    },
    Win32::{
        Foundation::{HMODULE, HWND},
        Graphics::{
            Direct3D::D3D_DRIVER_TYPE_HARDWARE,
            Direct3D11::{
                D3D11CreateDevice, ID3D11Device, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                D3D11_SDK_VERSION,
            },
            Dxgi::IDXGIDevice,
        },
        System::{
            Performance::{QueryPerformanceCounter, QueryPerformanceFrequency},
            WinRT::{
                Direct3D11::CreateDirect3D11DeviceFromDXGIDevice,
                Graphics::Capture::IGraphicsCaptureItemInterop, RoInitialize, RoUninitialize,
                RO_INIT_MULTITHREADED,
            },
        },
        UI::WindowsAndMessaging::{GetWindowThreadProcessId, IsWindow},
    },
};

struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}
struct Pool(Direct3D11CaptureFramePool);
impl Drop for Pool {
    fn drop(&mut self) {
        let _ = self.0.Close();
    }
}
struct Session(GraphicsCaptureSession);
impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.0.Close();
    }
}
struct Frame(Direct3D11CaptureFrame);
impl Drop for Frame {
    fn drop(&mut self) {
        let _ = self.0.Close();
    }
}

#[derive(Serialize)]
struct FrameInfo {
    width: i32,
    height: i32,
    frame_system_relative_100ns: i64,
    received_unix_ms: u128,
    preview_file: Option<String>,
}

#[derive(Serialize)]
struct CaptureResult {
    identity: Identity,
    hwnd: Option<usize>,
    frame: Option<FrameInfo>,
    unavailable: Option<String>,
}

fn verify(target: Identity, hwnd: HWND) -> Result<(), String> {
    let mut pid = 0;
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return Err("Target window disappeared".into());
        }
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
    }
    if pid != target.pid || identity(pid)? != target {
        return Err("Target window/process identity changed".into());
    }
    Ok(())
}

fn qpc_100ns() -> Result<i64, String> {
    let (mut counter, mut frequency) = (0, 0);
    unsafe {
        QueryPerformanceCounter(&mut counter).map_err(|e| e.to_string())?;
        QueryPerformanceFrequency(&mut frequency).map_err(|e| e.to_string())?;
    }
    if frequency <= 0 {
        return Err("Invalid performance counter frequency".into());
    }
    Ok(((counter as i128 * 10_000_000) / frequency as i128) as i64)
}

fn device() -> windows::core::Result<IDirect3DDevice> {
    unsafe {
        let mut device: Option<ID3D11Device> = None;
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            None,
        )?;
        let device = device.ok_or_else(|| {
            windows::core::Error::from_hresult(windows::core::HRESULT(0x80004003u32 as i32))
        })?;
        let dxgi: IDXGIDevice = device.cast()?;
        CreateDirect3D11DeviceFromDXGIDevice(&dxgi)?.cast()
    }
}

fn capture(target: Identity, handle: usize, directory: Option<&Path>) -> Result<FrameInfo, String> {
    let hwnd = HWND(handle as *mut _);
    verify(target, hwnd)?;
    let interop: IGraphicsCaptureItemInterop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(|e| e.to_string())?;
    let item: GraphicsCaptureItem =
        unsafe { interop.CreateForWindow(hwnd) }.map_err(|e| e.to_string())?;
    verify(target, hwnd)?;
    let size = item.Size().map_err(|e| e.to_string())?;
    if size.Width <= 0 || size.Height <= 0 {
        return Err("Target has no capture area".into());
    }
    let device = device().map_err(|e| e.to_string())?;
    let pool = Pool(
        Direct3D11CaptureFramePool::CreateFreeThreaded(
            &device,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            1,
            size,
        )
        .map_err(|e| e.to_string())?,
    );
    let session = Session(
        pool.0
            .CreateCaptureSession(&item)
            .map_err(|e| e.to_string())?,
    );
    verify(target, hwnd)?;
    let started = qpc_100ns()?;
    session.0.StartCapture().map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        verify(target, hwnd)?;
        match pool.0.TryGetNextFrame() {
            Ok(frame) => {
                let frame = Frame(frame);
                let timestamp = frame
                    .0
                    .SystemRelativeTime()
                    .map_err(|e| e.to_string())?
                    .Duration;
                if timestamp <= started {
                    continue;
                }
                let content = frame.0.ContentSize().map_err(|e| e.to_string())?;
                if content.Width <= 0 || content.Height <= 0 {
                    return Err("Frame has no content".into());
                }
                if content.Width != size.Width || content.Height != size.Height {
                    return Err("Window resized during capture; retry with a new snapshot".into());
                }
                verify(target, hwnd)?;
                let received_unix_ms = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis();
                let preview_file = if let Some(directory) = directory {
                    let bytes = super::readback::bmp(&frame.0, deadline)?;
                    verify(target, hwnd)?;
                    let path = directory.join(format!(
                        "rooc-{}-{}-{handle:x}-{received_unix_ms}.bmp",
                        target.pid, target.started_filetime
                    ));
                    use std::io::Write;
                    let mut file = std::fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&path)
                        .map_err(|e| format!("Cannot create preview: {e}"))?;
                    if let Err(e) = file.write_all(&bytes) {
                        drop(file);
                        let _ = std::fs::remove_file(&path);
                        return Err(format!("Cannot write preview: {e}"));
                    }
                    Some(path.to_string_lossy().into_owned())
                } else {
                    None
                };
                return Ok(FrameInfo {
                    width: content.Width,
                    height: content.Height,
                    frame_system_relative_100ns: timestamp,
                    received_unix_ms,
                    preview_file,
                });
            }
            // WinRT returns a null interface (E_POINTER) when no frame is ready.
            Err(e) if e.code() == windows::core::HRESULT(0x80004003u32 as i32) => {}
            Err(e) => return Err(format!("Frame acquisition failed: {e}")),
        }
        thread::sleep(Duration::from_millis(20));
    }
    Err("No fresh frame within 5 seconds".into())
}

pub fn run(snapshot: &Snapshot, directory: Option<&Path>) -> ExitCode {
    if !snapshot.errors.is_empty() {
        eprintln!(
            "Cannot safely capture an incomplete snapshot: {:?}",
            snapshot.errors
        );
        return ExitCode::from(3);
    }
    if snapshot.clients.is_empty() {
        println!("[]");
        return ExitCode::from(2);
    }
    if let Some(directory) = directory {
        if let Err(e) = std::fs::create_dir_all(directory) {
            eprintln!("Cannot create preview directory: {e}");
            return ExitCode::from(3);
        }
    }
    if let Err(e) = unsafe { RoInitialize(RO_INIT_MULTITHREADED) } {
        eprintln!("Cannot initialize Windows Runtime: {e}");
        return ExitCode::from(3);
    }
    let _apartment = Apartment;
    let support = GraphicsCaptureSession::IsSupported()
        .map_err(|e| e.to_string())
        .and_then(|supported| {
            if supported {
                Ok(())
            } else {
                Err("Windows Graphics Capture is not supported".into())
            }
        });
    let mut results = Vec::new();
    for client in &snapshot.clients {
        if client.windows.is_empty() {
            results.push(CaptureResult {
                identity: client.identity,
                hwnd: None,
                frame: None,
                unavailable: Some("No visible top-level game window".into()),
            });
        }
        for window in &client.windows {
            let result = support
                .clone()
                .and_then(|()| capture(client.identity, window.hwnd, directory));
            let (frame, unavailable) = match result {
                Ok(frame) => (Some(frame), None),
                Err(e) => (None, Some(e)),
            };
            results.push(CaptureResult {
                identity: client.identity,
                hwnd: Some(window.hwnd),
                frame,
                unavailable,
            });
        }
    }
    let failed = results.iter().any(|r| r.unavailable.is_some());
    match serde_json::to_string_pretty(&results) {
        Ok(json) => println!("{json}"),
        Err(e) => {
            eprintln!("Cannot serialize capture results: {e}");
            return ExitCode::from(3);
        }
    }
    ExitCode::from(u8::from(failed))
}
