/// Convert interleaved audio frames between common speaker layouts.
///
/// Channel order follows the conventional Symphonia/CPAL layouts:
/// mono; stereo; 3.0 (L, R, C); quad (L, R, BL, BR);
/// 5.1 (L, R, C, LFE, BL, BR); and 7.1
/// (L, R, C, LFE, BL, BR, SL, SR).
pub fn convert_channels(
    input: &[f32],
    in_channels: usize,
    out_channels: usize,
    output: &mut Vec<f32>,
) -> Result<(), String> {
    if in_channels == 0 || out_channels == 0 {
        return Err("Channel counts cannot be zero".into());
    }
    if input.len() % in_channels != 0 {
        return Err(format!(
            "Input length {} is not aligned to channel count {}",
            input.len(), in_channels
        ));
    }
    if in_channels == out_channels {
        output.extend_from_slice(input);
        return Ok(());
    }

    match (in_channels, out_channels) {
        (1, 2) => {
            for frame in input.chunks_exact(1) {
                output.extend_from_slice(&[frame[0], frame[0]]);
            }
        }
        (2, 1) => {
            for frame in input.chunks_exact(2) {
                output.push((frame[0] + frame[1]) * 0.5);
            }
        }
        (1, 4) => {
            for frame in input.chunks_exact(1) {
                output.extend_from_slice(&[frame[0], frame[0], frame[0], frame[0]]);
            }
        }
        (1, 6) => {
            for frame in input.chunks_exact(1) {
                let sample = frame[0];
                output.extend_from_slice(&[sample, sample, sample, 0.0, 0.0, 0.0]);
            }
        }
        (2, 4) => {
            for frame in input.chunks_exact(2) {
                output.extend_from_slice(&[frame[0], frame[1], frame[0], frame[1]]);
            }
        }
        (2, 6) => {
            for frame in input.chunks_exact(2) {
                let center = (frame[0] + frame[1]) * 0.5;
                output.extend_from_slice(&[frame[0], frame[1], center, 0.0, frame[0], frame[1]]);
            }
        }
        (3, 2) => {
            const NORM: f32 = 1.70710678;
            for frame in input.chunks_exact(3) {
                output.push((frame[0] + frame[2] * 0.70710678) / NORM);
                output.push((frame[1] + frame[2] * 0.70710678) / NORM);
            }
        }
        (4, 2) => {
            const NORM: f32 = 1.70710678;
            for frame in input.chunks_exact(4) {
                output.push((frame[0] + frame[2] * 0.70710678) / NORM);
                output.push((frame[1] + frame[3] * 0.70710678) / NORM);
            }
        }
        (6, 2) => {
            const NORM: f32 = 2.41421356;
            for frame in input.chunks_exact(6) {
                let left = frame[0] + frame[2] * 0.70710678 + frame[4] * 0.70710678;
                let right = frame[1] + frame[2] * 0.70710678 + frame[5] * 0.70710678;
                output.push(left / NORM);
                output.push(right / NORM);
            }
        }
        (8, 2) => {
            const NORM: f32 = 3.12132034;
            for frame in input.chunks_exact(8) {
                let left = frame[0]
                    + frame[2] * 0.70710678
                    + frame[4] * 0.70710678
                    + frame[6] * 0.70710678;
                let right = frame[1]
                    + frame[2] * 0.70710678
                    + frame[5] * 0.70710678
                    + frame[7] * 0.70710678;
                output.push(left / NORM);
                output.push(right / NORM);
            }
        }
        _ => {
            return Err(format!(
                "Unsupported channel conversion layout: {} -> {}",
                in_channels, out_channels
            ));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::convert_channels;

    #[test]
    fn mono_to_stereo_duplicates_each_frame() {
        let mut out = Vec::new();
        convert_channels(&[0.25, -0.5], 1, 2, &mut out).unwrap();
        assert_eq!(out, vec![0.25, 0.25, -0.5, -0.5]);
    }

    #[test]
    fn stereo_to_mono_averages_channels() {
        let mut out = Vec::new();
        convert_channels(&[1.0, -1.0, 0.5, 0.5], 2, 1, &mut out).unwrap();
        assert_eq!(out, vec![0.0, 0.5]);
    }

    #[test]
    fn stereo_to_surround_uses_defined_channel_order() {
        let mut out = Vec::new();
        convert_channels(&[0.5, -0.5], 2, 6, &mut out).unwrap();
        assert_eq!(out, vec![0.5, -0.5, 0.0, 0.0, 0.5, -0.5]);
    }

    #[test]
    fn five_one_to_stereo_downmixes_center_and_rear_channels() {
        let mut out = Vec::new();
        convert_channels(&[1.0, 1.0, 1.0, 0.0, 1.0, 1.0], 6, 2, &mut out).unwrap();
        assert!((out[0] - 1.0).abs() < 1e-5);
        assert!((out[1] - 1.0).abs() < 1e-5);
    }

    #[test]
    fn same_layout_is_preserved() {
        let mut out = vec![9.0];
        convert_channels(&[0.1, 0.2], 2, 2, &mut out).unwrap();
        assert_eq!(out, vec![9.0, 0.1, 0.2]);
    }

    #[test]
    fn rejects_malformed_and_unsupported_layouts() {
        let mut out = Vec::new();
        assert!(convert_channels(&[1.0, 2.0, 3.0], 2, 1, &mut out).is_err());
        assert!(convert_channels(&[1.0], 0, 2, &mut out).is_err());
        assert!(convert_channels(&[1.0, 2.0], 2, 8, &mut out).is_err());
    }
}
