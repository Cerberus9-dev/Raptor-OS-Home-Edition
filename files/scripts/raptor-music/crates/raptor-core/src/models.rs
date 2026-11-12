use uuid::Uuid;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaybackSource {
    LocalFile { path: PathBuf },
    RemoteStream { provider_id: String, provider_track_id: String },
    Unknown { raw_type: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Track {
    pub id: Uuid,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_secs: Option<u64>,
    pub source: PlaybackSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayerState {
    Idle,
    Loading,
    Playing,
    Paused,
    Buffering,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PlayerEvent {
    SessionStarted { session_token: Uuid, track_id: Uuid, queue_entry_id: Uuid },
    Paused { session_token: Uuid },
    Resumed { session_token: Uuid },
    Stopped { session_token: Uuid },
    PlaybackFailed { session_token: Uuid, error_message: String },
    NaturalEof { session_token: Uuid, queue_entry_id: Uuid },
    SessionTerminated { session_token: Uuid },
}


/// Playback permission is explicit metadata, not inferred from a provider's
/// ability to return a search result or preview URL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CataloguePlayback {
    FullLength,
    PreviewOnly,
    ExternalHandoff,
    Unavailable,
}

/// Provider-neutral recording identity and availability information.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogueCandidate {
    pub provider_id: String,
    pub provider_track_id: String,
    pub title: String,
    pub artist: String,
    pub isrc: Option<String>,
    pub duration_secs: Option<u64>,
    pub playback: CataloguePlayback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchConfidence {
    NeedsReview,
    ExactMetadata,
    ExactIsrc,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogueMatch {
    pub candidate: CatalogueCandidate,
    pub confidence: MatchConfidence,
}

/// Canonical identity for a playlist occurrence. The occurrence itself is
/// deliberately not deduplicated: two positions may refer to the same track.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackIdentity {
    pub title: String,
    pub artist: String,
    pub isrc: Option<String>,
    pub duration_secs: Option<u64>,
}

fn normalized_recording_text(value: &str) -> String {
    value.chars()
        .flat_map(char::to_lowercase)
        .filter(|ch| ch.is_alphanumeric())
        .collect()
}

fn normalized_isrc(value: &str) -> String {
    value.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_uppercase)
        .collect()
}

/// Match only recordings with a strong identity signal. A title-only or
/// artist-only hit is never enough to claim a successful playlist match.
pub fn rank_catalogue_candidates(
    target: &TrackIdentity,
    candidates: &[CatalogueCandidate],
) -> Vec<CatalogueMatch> {
    let target_isrc = target.isrc.as_deref()
        .map(normalized_isrc)
        .filter(|value| !value.is_empty());
    let target_title = normalized_recording_text(&target.title);
    let target_artist = normalized_recording_text(&target.artist);

    let mut matches = candidates.iter().filter_map(|candidate| {
        let candidate_isrc = candidate.isrc.as_deref()
            .map(normalized_isrc)
            .filter(|value| !value.is_empty());
        let confidence = if target_isrc.is_some() && candidate_isrc.is_some() && target_isrc != candidate_isrc {
            // Conflicting recording identifiers are stronger evidence than
            // similar titles and must never be overridden by fuzzy metadata.
            return None;
        } else if target_isrc.is_some() && target_isrc == candidate_isrc {
            MatchConfidence::ExactIsrc
        } else if !target_title.is_empty()
            && target_title == normalized_recording_text(&candidate.title)
            && !target_artist.is_empty()
            && target_artist == normalized_recording_text(&candidate.artist)
        {
            match (target.duration_secs, candidate.duration_secs) {
                (Some(left), Some(right)) if left.abs_diff(right) <= 3 => MatchConfidence::ExactMetadata,
                (None, _) | (_, None) => MatchConfidence::NeedsReview,
                _ => return None,
            }
        } else {
            return None;
        };
        Some(CatalogueMatch { candidate: candidate.clone(), confidence })
    }).collect::<Vec<_>>();

    matches.sort_by(|left, right| {
        right.confidence.cmp(&left.confidence)
            .then_with(|| {
                let access_rank = |access: CataloguePlayback| match access {
                    CataloguePlayback::FullLength => 3,
                    CataloguePlayback::PreviewOnly => 2,
                    CataloguePlayback::ExternalHandoff => 1,
                    CataloguePlayback::Unavailable => 0,
                };
                access_rank(right.candidate.playback).cmp(&access_rank(left.candidate.playback))
            })
            .then_with(|| left.candidate.provider_id.cmp(&right.candidate.provider_id))
    });
    matches
}

/// Select a full-length source only when the recording match is strong and
/// unambiguous. Preview and external-handoff results remain visible but can
/// never be promoted to full playback.
pub fn select_unambiguous_full_playback(matches: &[CatalogueMatch]) -> Option<&CatalogueCandidate> {
    let eligible = matches.iter().filter(|item| {
        item.candidate.playback == CataloguePlayback::FullLength
            && item.confidence >= MatchConfidence::ExactMetadata
    }).collect::<Vec<_>>();
    match eligible.as_slice() {
        [only] => Some(&only.candidate),
        [first, rest @ ..] => {
            let first_isrc = first.candidate.isrc.as_deref()
                .map(normalized_isrc)
                .filter(|value| !value.is_empty())?;
            if rest.iter().all(|item| {
                item.candidate.isrc.as_deref()
                    .map(normalized_isrc)
                    .as_deref() == Some(first_isrc.as_str())
            }) {
                Some(&first.candidate)
            } else {
                None
            }
        }
        [] => None,
    }
}

#[cfg(test)]
mod catalogue_matching_tests {
    use super::*;

    fn candidate(provider: &str, title: &str, artist: &str, isrc: Option<&str>,
                 duration: Option<u64>, playback: CataloguePlayback) -> CatalogueCandidate {
        CatalogueCandidate {
            provider_id: provider.into(),
            provider_track_id: format!("{provider}-track"),
            title: title.into(),
            artist: artist.into(),
            isrc: isrc.map(str::to_owned),
            duration_secs: duration,
            playback,
        }
    }

    fn target() -> TrackIdentity {
        TrackIdentity {
            title: "Night Drive".into(),
            artist: "Small Artist".into(),
            isrc: Some("USABC2600001".into()),
            duration_secs: Some(184),
        }
    }

    #[test]
    fn exact_isrc_matches_are_ranked_above_metadata_matches() {
        let rows = vec![
            candidate("metadata", "Night Drive", "Small Artist", None, Some(184), CataloguePlayback::FullLength),
            candidate("isrc", "Different display title", "Small Artist", Some("US-ABC-26-00001"), Some(190), CataloguePlayback::FullLength),
        ];
        let ranked = rank_catalogue_candidates(&target(), &rows);
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[0].candidate.provider_id, "isrc");
        assert_eq!(ranked[0].confidence, MatchConfidence::ExactIsrc);
        assert_eq!(ranked[1].confidence, MatchConfidence::ExactMetadata);
    }

    #[test]
    fn title_and_artist_without_duration_require_review() {
        let rows = vec![candidate("catalogue", "Night Drive", "Small Artist", None, None, CataloguePlayback::FullLength)];
        let ranked = rank_catalogue_candidates(&target(), &rows);
        assert_eq!(ranked[0].confidence, MatchConfidence::NeedsReview);
        assert!(select_unambiguous_full_playback(&ranked).is_none());
    }

    #[test]
    fn preview_and_external_handoff_are_never_selected_as_full_playback() {
        let rows = vec![
            candidate("preview", "Night Drive", "Small Artist", Some("USABC2600001"), Some(184), CataloguePlayback::PreviewOnly),
            candidate("external", "Night Drive", "Small Artist", Some("USABC2600001"), Some(184), CataloguePlayback::ExternalHandoff),
        ];
        let ranked = rank_catalogue_candidates(&target(), &rows);
        assert!(select_unambiguous_full_playback(&ranked).is_none());
    }

    #[test]
    fn distinct_full_length_recordings_with_same_metadata_are_not_auto_selected() {
        let rows = vec![
            candidate("provider-a", "Night Drive", "Small Artist", None, Some(184), CataloguePlayback::FullLength),
            candidate("provider-b", "Night Drive", "Small Artist", None, Some(184), CataloguePlayback::FullLength),
        ];
        let ranked = rank_catalogue_candidates(&target(), &rows);
        assert!(select_unambiguous_full_playback(&ranked).is_none());
    }

    #[test]
    fn multiple_full_length_sources_with_the_same_isrc_are_unambiguous() {
        let rows = vec![
            candidate("provider-a", "Night Drive", "Small Artist", Some("USABC2600001"), Some(184), CataloguePlayback::FullLength),
            candidate("provider-b", "Night Drive", "Small Artist", Some("US-ABC-26-00001"), Some(184), CataloguePlayback::FullLength),
        ];
        let ranked = rank_catalogue_candidates(&target(), &rows);
        assert!(select_unambiguous_full_playback(&ranked).is_some());
    }

    #[test]
    fn title_only_or_artist_only_results_are_not_matches() {
        let rows = vec![
            candidate("wrong-artist", "Night Drive", "Other Artist", None, Some(184), CataloguePlayback::FullLength),
            candidate("wrong-title", "Day Drive", "Small Artist", None, Some(184), CataloguePlayback::FullLength),
        ];
        assert!(rank_catalogue_candidates(&target(), &rows).is_empty());
    }

    #[test]
    fn conflicting_isrc_is_rejected_even_when_title_and_artist_match() {
        let rows = vec![candidate(
            "different-recording", "Night Drive", "Small Artist",
            Some("GBXYZ2600002"), Some(184), CataloguePlayback::FullLength,
        )];
        assert!(rank_catalogue_candidates(&target(), &rows).is_empty());
    }
}


/// Result for one playlist position. Rows are intentionally represented by
/// occurrence index rather than recording ID so repeated songs remain intact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaylistResolutionStatus {
    FullPlaybackAvailable { provider_id: String, provider_track_id: String },
    PreviewOnly,
    ExternalHandoff,
    Unavailable,
    NeedsReview,
    Unmatched,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaylistOccurrenceResolution {
    pub occurrence_index: usize,
    pub identity: TrackIdentity,
    pub status: PlaylistResolutionStatus,
    pub candidates: Vec<CatalogueMatch>,
}

/// Resolve a catalogue result set against every playlist occurrence. The
/// caller supplies the candidates gathered from provider adapters for each
/// occurrence. This function never removes duplicates and never upgrades a
/// preview or handoff into full playback.
pub fn resolve_playlist_occurrences(
    occurrences: &[TrackIdentity],
    candidates_by_occurrence: &[Vec<CatalogueCandidate>],
) -> Vec<PlaylistOccurrenceResolution> {
    occurrences.iter().enumerate().map(|(index, identity)| {
        let candidates = candidates_by_occurrence.get(index).map(Vec::as_slice).unwrap_or(&[]);
        let ranked = rank_catalogue_candidates(identity, candidates);
        let status = if let Some(candidate) = select_unambiguous_full_playback(&ranked) {
            PlaylistResolutionStatus::FullPlaybackAvailable {
                provider_id: candidate.provider_id.clone(),
                provider_track_id: candidate.provider_track_id.clone(),
            }
        } else if ranked.iter().any(|item| item.confidence == MatchConfidence::NeedsReview) {
            PlaylistResolutionStatus::NeedsReview
        } else if ranked.iter().any(|item| item.candidate.playback == CataloguePlayback::PreviewOnly) {
            PlaylistResolutionStatus::PreviewOnly
        } else if ranked.iter().any(|item| item.candidate.playback == CataloguePlayback::ExternalHandoff) {
            PlaylistResolutionStatus::ExternalHandoff
        } else if ranked.iter().any(|item| item.candidate.playback == CataloguePlayback::Unavailable) {
            PlaylistResolutionStatus::Unavailable
        } else {
            PlaylistResolutionStatus::Unmatched
        };
        PlaylistOccurrenceResolution {
            occurrence_index: index,
            identity: identity.clone(),
            status,
            candidates: ranked,
        }
    }).collect()
}

#[cfg(test)]
mod playlist_resolution_tests {
    use super::*;

    fn identity(title: &str) -> TrackIdentity {
        TrackIdentity { title: title.into(), artist: "Artist".into(), isrc: Some("USABC2600001".into()), duration_secs: Some(180) }
    }

    fn candidate(provider: &str, playback: CataloguePlayback) -> CatalogueCandidate {
        CatalogueCandidate {
            provider_id: provider.into(),
            provider_track_id: format!("{provider}-id"),
            title: "Song".into(),
            artist: "Artist".into(),
            isrc: Some("USABC2600001".into()),
            duration_secs: Some(180),
            playback,
        }
    }

    #[test]
    fn keeps_duplicate_playlist_occurrences_as_separate_results() {
        let rows = vec![identity("Song"), identity("Song"), identity("Other")];
        let candidates = vec![
            vec![candidate("audius", CataloguePlayback::FullLength)],
            vec![candidate("audius", CataloguePlayback::FullLength)],
            vec![],
        ];
        let resolved = resolve_playlist_occurrences(&rows, &candidates);
        assert_eq!(resolved.len(), 3);
        assert_eq!(resolved[0].occurrence_index, 0);
        assert_eq!(resolved[1].occurrence_index, 1);
        assert_eq!(resolved[0].status, resolved[1].status);
        assert_eq!(resolved[2].status, PlaylistResolutionStatus::Unmatched);
    }

    #[test]
    fn does_not_treat_preview_or_handoff_as_full_playback() {
        let rows = vec![identity("Song"), identity("Song")];
        let candidates = vec![
            vec![candidate("apple_music", CataloguePlayback::PreviewOnly)],
            vec![candidate("tidal", CataloguePlayback::ExternalHandoff)],
        ];
        let resolved = resolve_playlist_occurrences(&rows, &candidates);
        assert_eq!(resolved[0].status, PlaylistResolutionStatus::PreviewOnly);
        assert_eq!(resolved[1].status, PlaylistResolutionStatus::ExternalHandoff);
    }

    #[test]
    fn reports_candidate_batch_missing_for_an_occurrence_as_unmatched() {
        let rows = vec![identity("Song"), identity("Song")];
        let candidates = vec![vec![candidate("audius", CataloguePlayback::FullLength)]];
        let resolved = resolve_playlist_occurrences(&rows, &candidates);
        assert_eq!(resolved.len(), 2);
        assert_eq!(resolved[1].status, PlaylistResolutionStatus::Unmatched);
    }
}
