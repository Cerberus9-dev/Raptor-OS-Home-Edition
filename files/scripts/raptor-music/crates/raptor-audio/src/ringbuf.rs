use ringbuf::{HeapConsumer, HeapProducer, HeapRb};

pub fn make_spsc(capacity: usize) -> (HeapProducer<f32>, HeapConsumer<f32>) {
    let rb = HeapRb::<f32>::new(capacity);
    rb.split()
}

/// Push only complete interleaved frames. Returns the number of samples pushed.
pub fn push_frames(producer: &mut HeapProducer<f32>, frames: &[f32], channels: usize) -> usize {
    if channels == 0 || frames.is_empty() {
        return 0;
    }
    let total_frames = frames.len() / channels;
    let available_slots = producer.free_len();
    let frames_to_push = std::cmp::min(total_frames, available_slots / channels);
    let samples_to_push = frames_to_push * channels;
    let pushed = producer.push_slice(&frames[..samples_to_push]);
    (pushed / channels) * channels
}

/// Pop only complete interleaved frames. The caller owns underrun fill behavior.
pub fn pop_frames(consumer: &mut HeapConsumer<f32>, output: &mut [f32], channels: usize) -> usize {
    if channels == 0 || output.is_empty() {
        return 0;
    }
    let total_output_frames = output.len() / channels;
    let available_samples = consumer.len();
    let available_frames = available_samples / channels;
    let frames_to_pop = std::cmp::min(total_output_frames, available_frames);
    let samples_to_pop = frames_to_pop * channels;
    let popped = consumer.pop_slice(&mut output[..samples_to_pop]);
    (popped / channels) * channels
}

#[cfg(test)]
mod tests {
    use super::{make_spsc, pop_frames, push_frames};

    #[test]
    fn producer_and_consumer_transfer_complete_stereo_frames() {
        let (mut producer, mut consumer) = make_spsc(8);
        assert_eq!(push_frames(&mut producer, &[1.0, 2.0, 3.0, 4.0], 2), 4);
        let mut output = [0.0; 4];
        assert_eq!(pop_frames(&mut consumer, &mut output, 2), 4);
        assert_eq!(output, [1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn capacity_limits_push_without_splitting_frames() {
        let (mut producer, mut consumer) = make_spsc(3);
        assert_eq!(push_frames(&mut producer, &[1.0, 2.0, 3.0, 4.0], 2), 2);
        let mut output = [0.0; 4];
        assert_eq!(pop_frames(&mut consumer, &mut output, 2), 2);
        assert_eq!(&output[..2], &[1.0, 2.0]);
    }

    #[test]
    fn incomplete_input_and_output_samples_are_not_transferred() {
        let (mut producer, mut consumer) = make_spsc(8);
        assert_eq!(push_frames(&mut producer, &[1.0, 2.0, 99.0], 2), 2);
        let mut output = [0.0; 5];
        assert_eq!(pop_frames(&mut consumer, &mut output, 2), 2);
        assert_eq!(&output[..2], &[1.0, 2.0]);
        assert_eq!(output[2], 0.0);
    }

    #[test]
    fn zero_channel_requests_are_safe_noops() {
        let (mut producer, mut consumer) = make_spsc(4);
        assert_eq!(push_frames(&mut producer, &[1.0], 0), 0);
        let mut output = [0.0; 2];
        assert_eq!(pop_frames(&mut consumer, &mut output, 0), 0);
    }
}
