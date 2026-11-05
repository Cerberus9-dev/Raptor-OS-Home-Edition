/// Streaming linear sample-rate converter.
///
/// Input and output are interleaved frames. The converter retains the previous
/// input frame and the absolute position of the next output frame, so packet
/// boundaries do not reset interpolation phase.
pub struct LinearResampler {
    channels: usize,
    input_per_output: f64,
    next_output_position: f64,
    input_frames_seen: u64,
    previous_frame: Vec<f32>,
    has_previous: bool,
}

impl LinearResampler {
    pub fn new(channels: usize, in_rate: u32, out_rate: u32) -> Result<Self, String> {
        if channels == 0 {
            return Err("Channel count cannot be zero".into());
        }
        if in_rate == 0 || out_rate == 0 {
            return Err("Sample rates cannot be zero".into());
        }

        Ok(Self {
            channels,
            input_per_output: in_rate as f64 / out_rate as f64,
            next_output_position: 0.0,
            input_frames_seen: 0,
            previous_frame: vec![0.0; channels],
            has_previous: false,
        })
    }

    pub fn process(&mut self, input: &[f32], output: &mut Vec<f32>) -> Result<(), String> {
        if input.len() % self.channels != 0 {
            return Err(format!(
                "Malformed input: length {} is not divisible by channel count {}",
                input.len(), self.channels
            ));
        }

        for frame in input.chunks_exact(self.channels) {
            if !self.has_previous {
                self.previous_frame.copy_from_slice(frame);
                self.has_previous = true;
                self.input_frames_seen = 1;
                continue;
            }

            let current_position = self.input_frames_seen as f64;
            let interval_start = current_position - 1.0;

            // Emit every output sample whose source position lies in the
            // interval [previous_frame, current_frame]. This handles both
            // upsampling (multiple outputs per interval) and downsampling
            // (intervals with no output) without negative interpolation.
            while self.next_output_position <= current_position + 1e-12 {
                let fraction = (self.next_output_position - interval_start)
                    .clamp(0.0, 1.0) as f32;
                for channel in 0..self.channels {
                    let a = self.previous_frame[channel];
                    let b = frame[channel];
                    output.push(a + (b - a) * fraction);
                }
                self.next_output_position += self.input_per_output;
            }

            self.previous_frame.copy_from_slice(frame);
            self.input_frames_seen = self.input_frames_seen.saturating_add(1);
        }

        Ok(())
    }

    /// Linear interpolation needs two input frames. The final input frame is
    /// emitted only if it is exactly on the output sampling grid; otherwise
    /// extrapolating beyond the final frame would invent audio data.
    pub fn flush(&mut self, output: &mut Vec<f32>) {
        if self.has_previous {
            let final_input_position = self.input_frames_seen.saturating_sub(1) as f64;
            if (self.next_output_position - final_input_position).abs() <= 1e-9 {
                output.extend_from_slice(&self.previous_frame);
            }
        }
        self.next_output_position = 0.0;
        self.input_frames_seen = 0;
        self.has_previous = false;
        self.previous_frame.fill(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::LinearResampler;

    #[test]
    fn equal_rate_preserves_samples_across_packet_boundaries() {
        let mut r = LinearResampler::new(1, 48_000, 48_000).unwrap();
        let mut out = Vec::new();
        r.process(&[0.0, 1.0], &mut out).unwrap();
        r.process(&[2.0, 3.0], &mut out).unwrap();
        r.flush(&mut out);
        assert_eq!(out, vec![0.0, 1.0, 2.0, 3.0]);
    }

    #[test]
    fn upsampling_interpolates_without_negative_extrapolation() {
        let mut r = LinearResampler::new(1, 2, 4).unwrap();
        let mut out = Vec::new();
        r.process(&[0.0, 1.0, 2.0], &mut out).unwrap();
        r.flush(&mut out);
        assert_eq!(out.len(), 5);
        assert_eq!(out[0], 0.0);
        assert!((out[1] - 0.5).abs() < 1e-6);
        assert_eq!(out[2], 1.0);
        assert!((out[3] - 1.5).abs() < 1e-6);
        assert_eq!(out[4], 2.0);
        assert!(out.iter().all(|sample| *sample >= 0.0));
    }

    #[test]
    fn downsampling_keeps_output_positions_on_input_grid() {
        let mut r = LinearResampler::new(1, 4, 2).unwrap();
        let mut out = Vec::new();
        r.process(&[0.0, 1.0, 2.0, 3.0, 4.0], &mut out).unwrap();
        r.flush(&mut out);
        assert_eq!(out, vec![0.0, 2.0, 4.0]);
    }

    #[test]
    fn stereo_channels_keep_independent_interpolation() {
        let mut r = LinearResampler::new(2, 2, 4).unwrap();
        let mut out = Vec::new();
        r.process(&[0.0, 10.0, 1.0, 20.0], &mut out).unwrap();
        assert_eq!(out.len(), 6);
        assert_eq!(out[0..2], [0.0, 10.0]);
        assert_eq!(out[2..4], [0.5, 15.0]);
        assert_eq!(out[4..6], [1.0, 20.0]);
    }

    #[test]
    fn rejects_partial_interleaved_frame() {
        let mut r = LinearResampler::new(2, 44_100, 48_000).unwrap();
        let mut out = Vec::new();
        assert!(r.process(&[0.0, 1.0, 2.0], &mut out).is_err());
    }

    #[test]
    fn rejects_zero_rates_and_channels() {
        assert!(LinearResampler::new(0, 44_100, 48_000).is_err());
        assert!(LinearResampler::new(2, 0, 48_000).is_err());
        assert!(LinearResampler::new(2, 44_100, 0).is_err());
    }
}
