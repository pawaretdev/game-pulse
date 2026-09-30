use std::{
    thread,
    time::{Duration, Instant},
};
use windows::{
    core::Interface,
    Graphics::Capture::Direct3D11CaptureFrame,
    Win32::{
        Graphics::{
            Direct3D11::{
                ID3D11DeviceContext, ID3D11Texture2D, D3D11_CPU_ACCESS_READ,
                D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_FLAG_DO_NOT_WAIT, D3D11_MAP_READ,
                D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
            },
            Dxgi::{Common::DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ERROR_WAS_STILL_DRAWING},
        },
        System::WinRT::Direct3D11::IDirect3DDxgiInterfaceAccess,
    },
};

struct Mapped<'a> {
    context: &'a ID3D11DeviceContext,
    texture: &'a ID3D11Texture2D,
}
impl Drop for Mapped<'_> {
    fn drop(&mut self) {
        unsafe {
            self.context.Unmap(self.texture, 0);
        }
    }
}

pub(super) fn bmp(frame: &Direct3D11CaptureFrame, deadline: Instant) -> Result<Vec<u8>, String> {
    let access: IDirect3DDxgiInterfaceAccess = frame
        .Surface()
        .map_err(|e| e.to_string())?
        .cast()
        .map_err(|e| e.to_string())?;
    unsafe {
        let source: ID3D11Texture2D = access.GetInterface().map_err(|e| e.to_string())?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        source.GetDesc(&mut desc);
        let content = frame.ContentSize().map_err(|e| e.to_string())?;
        if content.Width <= 0
            || content.Height <= 0
            || desc.Width != content.Width as u32
            || desc.Height != content.Height as u32
        {
            return Err("Capture texture and content size differ; preview unavailable".into());
        }
        let row_bytes = (desc.Width as usize)
            .checked_mul(4)
            .ok_or("Frame width overflow")?;
        let bytes = row_bytes
            .checked_mul(desc.Height as usize)
            .ok_or("Frame size overflow")?;
        if desc.Width == 0
            || desc.Height == 0
            || bytes > crate::preview::MAX_PIXEL_BYTES
            || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM
            || desc.ArraySize != 1
            || desc.MipLevels != 1
            || desc.SampleDesc.Count != 1
        {
            return Err("Unsupported or oversized capture texture (64 MiB pixel limit)".into());
        }
        let device = source.GetDevice().map_err(|e| e.to_string())?;
        let context = device.GetImmediateContext().map_err(|e| e.to_string())?;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
        desc.MiscFlags = 0;
        let mut staging = None;
        device
            .CreateTexture2D(&desc, None, Some(&mut staging))
            .map_err(|e| e.to_string())?;
        let staging = staging.ok_or("Cannot allocate readback texture")?;
        context.CopyResource(&staging, &source);
        context.Flush();
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        loop {
            if Instant::now() >= deadline {
                return Err("GPU readback timed out".into());
            }
            match context.Map(
                &staging,
                0,
                D3D11_MAP_READ,
                D3D11_MAP_FLAG_DO_NOT_WAIT.0 as u32,
                Some(&mut mapped),
            ) {
                Ok(()) => break,
                Err(e) if e.code() == DXGI_ERROR_WAS_STILL_DRAWING => {
                    thread::sleep(Duration::from_millis(20))
                }
                Err(e) => return Err(format!("GPU readback failed: {e}")),
            }
        }
        let guard = Mapped {
            context: &context,
            texture: &staging,
        };
        if mapped.pData.is_null() || (mapped.RowPitch as usize) < row_bytes {
            return Err("Invalid mapped capture texture".into());
        }
        let mut pixels = Vec::with_capacity(bytes);
        for row in 0..desc.Height as usize {
            // D3D11 guarantees Height rows at RowPitch stride while mapped.
            let source = mapped
                .pData
                .cast::<u8>()
                .add(row * mapped.RowPitch as usize);
            pixels.extend_from_slice(std::slice::from_raw_parts(source, row_bytes));
        }
        drop(guard);
        crate::preview::bmp(desc.Width, desc.Height, &pixels)
    }
}
