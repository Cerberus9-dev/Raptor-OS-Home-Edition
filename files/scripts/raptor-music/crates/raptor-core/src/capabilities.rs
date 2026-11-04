#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioCapability {
    LocalPlayback,
    Resampling,
    ChannelDownmixing,
}

pub fn get_supported_capabilities() -> Vec<AudioCapability> {
    vec![
        AudioCapability::LocalPlayback,
        AudioCapability::Resampling,
        AudioCapability::ChannelDownmixing,
    ]
}
