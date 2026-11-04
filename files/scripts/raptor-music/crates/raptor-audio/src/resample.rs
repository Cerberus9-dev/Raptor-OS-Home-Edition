pub struct LinearResampler {
    channels: usize,
    in_rate: f64,
    out_rate: f64,
    phase: f64,
    prev_frame: Vec<f32>,
    curr_frame: Vec<f32>,
    has_prev: bool,
    has_curr: bool,
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
            in_rate: in_rate as f64,
            out_rate: out_rate as f64,
            phase: 0.0,
            prev_frame: vec![0.0; channels],
            curr_frame: vec![0.0; channels],
            has_prev: false,
            has_curr: false,
        })
    }

    pub fn process(&mut self, input: &[f32], output: &mut Vec<f32>) -> Result<(), String> {
        if input.is_empty() {
            return Ok(());
        }
        if input.len() % self.channels != 0 {
            return Err(format!("Malformed input: length {} is not divisible by channel count {}", input.len(), self.channels));
        }
        let ratio = self.in_rate / self.out_rate;
        let frames = input.chunks_exact(self.channels);

        for frame in frames {
            if !self.has_prev {
                self.prev_frame.copy_from_slice(frame);
                self.has_prev = true;
                continue;
            }
            if !self.has_curr {
                self.curr_frame.copy_from_slice(frame);
                self.has_curr = true;
            } else {
                self.prev_frame.copy_from_slice(&self.curr_frame);
                self.curr_frame.copy_from_slice(frame);
            }

            while self.phase < 1.0 {
                let p = self.phase as f32;
                for c in 0..self.channels {
                    let val = self.prev_frame[c] + (self.curr_frame[c] - self.prev_frame[c]) * p;
                    output.push(val);
                }
                self.phase += ratio;
            }
            self.phase -= 1.0;
        }
        Ok(())
    }

    pub fn flush(&mut self, output: &mut Vec<f32>) {
        if self.has_prev && !self.has_curr {
            for c in 0..self.channels {
                output.push(self.prev_frame[c]);
            }
        } else if self.has_prev && self.has_curr {
            if self.phase < 1.0 && (self.phase - 0.0).abs() > 1e-6 {
                let p = self.phase as f32;
                for c in 0..self.channels {
                    let val = self.prev_frame[c] + (self.curr_frame[c] - self.prev_frame[c]) * p;
                    output.push(val);
                }
            } else {
                for c in 0..self.channels {
                    output.push(self.curr_frame[c]);
                }
            }
        }
        self.phase = 0.0;
        self.has_prev = false;
        self.has_curr = false;
    }
}
