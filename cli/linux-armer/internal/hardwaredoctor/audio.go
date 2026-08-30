package hardwaredoctor

import (
	"context"
	"errors"
	"io/fs"
	"regexp"
	"strings"
	"time"
)

const (
	// maximumALSACardsBytes bounds the live ALSA card inventory.
	maximumALSACardsBytes int64 = 16 << 10
	// maximumALSAPCMBytes bounds the live ALSA PCM endpoint inventory.
	maximumALSAPCMBytes int64 = 32 << 10
)

// alsaCardPattern identifies card records without retaining their names.
var alsaCardPattern = regexp.MustCompile(`(?m)^\s*[0-9]+\s+\[[^\]\r\n]{1,64}\]`)

// alsaPlaybackPattern identifies a non-zero playback endpoint count.
var alsaPlaybackPattern = regexp.MustCompile(`(?i)\bplayback\s+[1-9][0-9]*\b`)

// alsaCapturePattern identifies a non-zero capture endpoint count.
var alsaCapturePattern = regexp.MustCompile(`(?i)\bcapture\s+[1-9][0-9]*\b`)

// audioCardState aggregates ALSA card presence without retaining card labels.
type audioCardState struct {
	// cards is the bounded number of ALSA cards.
	cards int
	// surfaceCard records the expected Qualcomm X1E Surface card identity.
	surfaceCard bool
	// unavailable records whether the card inventory could not be read safely.
	unavailable bool
}

// audioPCMState aggregates playback and capture endpoint availability.
type audioPCMState struct {
	// playback records whether ALSA exposes at least one playback endpoint.
	playback bool
	// capture records whether ALSA exposes at least one capture endpoint.
	capture bool
	// unavailable records whether the PCM inventory could not be read safely.
	unavailable bool
}

// inspectAudio reports ALSA and session readiness without playing or recording.
func (doctor *Doctor) inspectAudio(ctx context.Context, probeTimeout time.Duration) ([]Check, error) {
	checks := make([]Check, 0, 5)
	cards := doctor.readAudioCards(ctx)
	switch {
	case cards.unavailable:
		checks = append(checks, Check{ID: "audio-alsa-surface-card", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "the live ALSA card inventory could not be read safely"})
	case cards.cards == 0:
		checks = append(checks, Check{ID: "audio-alsa-surface-card", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "ALSA exposes no sound card"})
	case !cards.surfaceCard:
		checks = append(checks, Check{ID: "audio-alsa-surface-card", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "ALSA exposes sound hardware but not the expected Qualcomm X1E Surface card", Remediation: "run the static audio userspace doctor, then review bounded kernel audio messages locally"})
	default:
		checks = append(checks, Check{ID: "audio-alsa-surface-card", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "ALSA exposes the expected Qualcomm X1E Surface card"})
	}
	pcm := doctor.readAudioPCM(ctx)
	switch {
	case pcm.unavailable:
		checks = append(checks, Check{ID: "audio-alsa-playback", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "the live ALSA playback inventory could not be read safely"})
	case !pcm.playback:
		checks = append(checks, Check{ID: "audio-alsa-playback", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "ALSA exposes no playback endpoint for the current boot"})
	default:
		checks = append(checks, Check{ID: "audio-alsa-playback", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "ALSA exposes a playback endpoint"})
	}
	switch {
	case pcm.unavailable:
		checks = append(checks, Check{ID: "audio-alsa-capture", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateUnavailable, Required: false, Detail: "the live ALSA capture inventory could not be read safely"})
	case !pcm.capture:
		checks = append(checks, Check{ID: "audio-alsa-capture", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StateWarn, Required: false, Detail: "ALSA exposes no capture endpoint for the current boot"})
	default:
		checks = append(checks, Check{ID: "audio-alsa-capture", Feature: FeatureAudio, Evidence: EvidenceRuntime, State: StatePass, Required: false, Detail: "ALSA exposes a capture endpoint"})
	}
	sessionResult, sessionOutcome, err := doctor.runProbe(ctx, ProbeAudioSession, probeTimeout)
	if err != nil {
		return nil, err
	}
	checks = append(checks, audioSessionCheck(sessionResult, sessionOutcome))
	checks = append(checks, hardwareLimitation(FeatureAudio))
	return checks, nil
}

// readAudioCards classifies the bounded procfs inventory in memory.
func (doctor *Doctor) readAudioCards(ctx context.Context) audioCardState {
	content, err := doctor.filesystem.ReadFile(ctx, "/proc/asound/cards", maximumALSACardsBytes)
	if errors.Is(err, fs.ErrNotExist) {
		return audioCardState{}
	}
	if err != nil {
		return audioCardState{unavailable: true}
	}
	lower := strings.ToLower(string(content))
	return audioCardState{
		cards:       len(alsaCardPattern.FindAll(content, -1)),
		surfaceCard: strings.Contains(lower, "x1e80100") && (strings.Contains(lower, "microso") || strings.Contains(lower, "surface")),
	}
}

// readAudioPCM classifies endpoint capabilities without returning device labels.
func (doctor *Doctor) readAudioPCM(ctx context.Context) audioPCMState {
	content, err := doctor.filesystem.ReadFile(ctx, "/proc/asound/pcm", maximumALSAPCMBytes)
	if errors.Is(err, fs.ErrNotExist) {
		return audioPCMState{}
	}
	if err != nil {
		return audioPCMState{unavailable: true}
	}
	return audioPCMState{
		playback: alsaPlaybackPattern.Match(content),
		capture:  alsaCapturePattern.Match(content),
	}
}

// audioSessionCheck reports only whether the current user's audio server responds.
func audioSessionCheck(result ProbeResult, outcome probeOutcome) Check {
	check := Check{ID: "audio-session-server", Feature: FeatureAudio, Evidence: EvidenceRuntime, Required: false}
	switch {
	case outcome == probeTimedOut:
		check.State = StateUnavailable
		check.Detail = "the bounded desktop audio-session probe timed out"
	case outcome != probeCompleted:
		check.State = StateUnavailable
		check.Detail = "the current user's desktop audio session could not be inspected with the fixed probe"
	case result.ExitCode != 0:
		check.State = StateWarn
		check.Detail = "the current user's PulseAudio-compatible session is not reachable"
		check.Remediation = "rerun the live doctor inside the intended desktop login session"
	default:
		check.State = StatePass
		check.Detail = "the current user's PulseAudio-compatible session is reachable"
	}
	return check
}
