//! Bounded, top-down 32-bit BMP for explicitly requested diagnostic previews.
// Four 4K monitors require roughly 127 MiB in BGRA form. Keep the allocation
// bounded while leaving enough room for common multi-monitor desktops.
pub const MAX_PIXEL_BYTES: usize = 256 * 1024 * 1024;

pub fn bmp(width: u32, height: u32, bgra: &[u8]) -> Result<Vec<u8>, String> {
    let size = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
        .ok_or("Preview size overflow")?;
    if width == 0
        || height == 0
        || width > i32::MAX as u32
        || height > i32::MAX as u32
        || size > MAX_PIXEL_BYTES
        || bgra.len() != size
    {
        return Err("Invalid or oversized preview buffer".into());
    }
    let mut result = vec![0u8; 54];
    result[0..2].copy_from_slice(b"BM");
    result[2..6].copy_from_slice(&((54 + size) as u32).to_le_bytes());
    result[10..14].copy_from_slice(&54u32.to_le_bytes());
    result[14..18].copy_from_slice(&40u32.to_le_bytes());
    result[18..22].copy_from_slice(&(width as i32).to_le_bytes());
    result[22..26].copy_from_slice(&(-(height as i32)).to_le_bytes());
    result[26..28].copy_from_slice(&1u16.to_le_bytes());
    result[28..30].copy_from_slice(&32u16.to_le_bytes());
    result[34..38].copy_from_slice(&(size as u32).to_le_bytes());
    result.extend_from_slice(bgra);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preview_preserves_top_down_pixel_order_and_bgra_channels() {
        let pixels = [0, 0, 255, 255, 255, 0, 0, 255];
        let image = bmp(1, 2, &pixels).unwrap();
        assert_eq!(&image[..2], b"BM");
        assert_eq!(
            u32::from_le_bytes(image[2..6].try_into().unwrap()) as usize,
            image.len()
        );
        assert_eq!(i32::from_le_bytes(image[22..26].try_into().unwrap()), -2);
        assert_eq!(&image[54..], &pixels);
    }
    #[test]
    fn preview_rejects_invalid_dimensions_and_truncated_buffers() {
        for (w, h) in [(0, 1), (1, 0), (1, 1), (u32::MAX, u32::MAX), (8192, 8192)] {
            assert!(bmp(w, h, &[]).is_err());
        }
    }
}
