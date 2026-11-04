use std::fs::File;
use std::path::Path;
use symphonia::core::audio::AudioBufferRef;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

pub struct AudioMetadata {
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_secs: Option<u64>,
}

pub struct AudioDecoder {
    format_reader: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    sample_rate: u32,
    channels: usize,
    duration_secs: Option<u64>,
}

impl AudioDecoder {
    pub fn extract_metadata(path: &Path) -> Result<AudioMetadata, String> {
        let file = File::open(path).map_err(|e| format!("Failed to open file: {}", e))?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .map_err(|e| format!("Failed to probe format: {}", e))?;

        let format_reader = probed.format;
        let track = format_reader
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != syms_codecs_null())
            .ok_or_else(|| "No supported audio tracks found".to_string())?;

        let duration_secs = track.codec_params.n_frames.and_then(|frames| {
            track.codec_params.sample_rate.map(|sr| frames / sr as u64)
        });

        let mut title = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
        let mut artist = "Unknown Artist".to_string();
        let mut album = None;

        if let Some(metadata) = format_reader.metadata().current() {
            for tag in metadata.tags() {
                match tag.std_key {
                    Some(symphonia::core::meta::StandardTagKey::TrackTitle) => {
                        title = tag.value.to_string();
                    }
                    Some(symphonia::core::meta::StandardTagKey::Artist) => {
                        artist = tag.value.to_string();
                    }
                    Some(symphonia::core::meta::StandardTagKey::Album) => {
                        album = Some(tag.value.to_string());
                    }
                    _ => {}
                }
            }
        }

        Ok(AudioMetadata {
            title,
            artist,
            album,
            duration_secs,
        })
    }

    pub fn new(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|e| format!("Failed to open file: {}", e))?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .map_err(|e| format!("Unsupported format or decode error: {}", e))?;

        let format_reader = probed.format;
        let track = format_reader
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != syms_codecs_null())
            .ok_or_else(|| "No supported audio tracks found".to_string())?;

        let track_id = track.id;
        let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(2);
        let duration_secs = track.codec_params.n_frames.and_then(|frames| {
            track.codec_params.sample_rate.map(|sr| frames / sr as u64)
        });

        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|e| format!("Failed to create decoder: {}", e))?;

        Ok(Self {
            format_reader,
            decoder,
            track_id,
            sample_rate,
            channels,
            duration_secs,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn duration_secs(&self) -> Option<u64> {
        self.duration_secs
    }

    pub fn next_packet_samples(&mut self) -> Result<Option<AudioBufferRef<'_>>, String> {
        loop {
            let packet = match self.format_reader.next_packet() {
                Ok(packet) => packet,
                Err(SymphoniaError::IoError(err)) => {
                    if err.kind() == std::io::ErrorKind::UnexpectedEof {
                        return Ok(None);
                    }
                    return Err(format!("I/O Error during decode: {}", err));
                }
                Err(SymphoniaError::ResetRequired) => {
                    return Err("Reset required during decoding".into());
                }
                Err(e) => return Err(format!("Decoding packet error: {}", e)),
            };

            if packet.track_id() != self.track_id {
                continue;
            }

            match self.decoder.decode(&packet) {
                Ok(decoded) => return Ok(Some(decoded)),
                Err(SymphoniaError::DecodeError(_)) => continue,
                Err(SymphoniaError::IoError(err)) => {
                    if err.kind() == std::io::ErrorKind::UnexpectedEof {
                        return Ok(None);
                    }
                    return Err(format!("I/O Error during packet decode: {}", err));
                }
                Err(e) => return Err(format!("Audio decode error: {}", e)),
            }
        }
    }
}

fn syms_codecs_null() -> symphonia::core::codecs::CodecType {
    symphonia::core::codecs::CODEC_TYPE_NULL
}
