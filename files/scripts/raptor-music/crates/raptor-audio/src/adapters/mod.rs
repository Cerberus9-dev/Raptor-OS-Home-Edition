//! Concrete provider adapters. Provider response JSON is normalized here;
//! the UI and queue only receive raptor_core::models::UnifiedTrack.

mod bandcamp;
mod spotify;
mod youtube;

pub use bandcamp::BandcampAdapter;
pub use spotify::SpotifyAdapter;
pub use youtube::YouTubeAdapter;
