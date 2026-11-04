use ringbuf::{HeapRb, Producer, Consumer};

pub fn make_spsc(capacity: usize) -> (Producer<f32>, Consumer<f32>) {
    let rb = HeapRb::<f32>::new(capacity);
    rb.split()
}

pub fn push_frames(producer: &mut Producer<f32>, frames: &[f32], channels: usize) -> usize {
    if channels == 0 || frames.is_empty() {
        return 0;
    }
    let total_frames = frames.len() / channels;
    let available_slots = producer.remaining();
    let frames_to_push = std::cmp::min(total_frames, available_slots / channels);
    let samples_to_push = frames_to_push * channels;
    let pushed = producer.push_slice(&frames[..samples_to_push]);
    (pushed / channels) * channels
}

pub fn pop_frames(consumer: &mut Consumer<f32>, output: &mut [f32], channels: usize) -> usize {
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
