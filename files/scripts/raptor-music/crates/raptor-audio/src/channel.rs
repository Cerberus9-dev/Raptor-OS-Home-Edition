pub fn convert_channels(input: &[f32], in_channels: usize, out_channels: usize, output: &mut Vec<f32>) -> Result<(), String> {
    if in_channels == 0 || out_channels == 0 {
        return Err("Channel counts cannot be zero".into());
    }
    if input.len() % in_channels != 0 {
        return Err(format!("Input length {} is not aligned to channel count {}", input.len(), in_channels));
    }

    if in_channels == out_channels {
        output.extend_from_slice(input);
        return Ok(());
    }

    let frames = input.chunks_exact(in_channels);

    match (in_channels, out_channels) {
        (1, 2) => {
            for frame in frames {
                let s = frame[0];
                output.push(s);
                output.push(s);
            }
        }
        (2, 1) => {
            for frame in frames {
                let mono = (frame[0] + frame[1]) * 0.5;
                output.push(mono);
            }
        }
        (6, 2) => {
            const NORM: f32 = 2.41421356;
            for frame in frames {
                let l = frame[0];
                let r = frame[1];
                let c = frame[2];
                let ls = frame[4];
                let rs = frame[5];

                let left_sum = l + c * 0.70710678 + ls * 0.70710678;
                let right_sum = r + c * 0.70710678 + rs * 0.70710678;

                output.push(left_sum / NORM);
                output.push(right_sum / NORM);
            }
        }
        _ => {
            return Err(format!("Unsupported channel conversion layout: {} -> {}", in_channels, out_channels));
        }
    }

    Ok(())
}
