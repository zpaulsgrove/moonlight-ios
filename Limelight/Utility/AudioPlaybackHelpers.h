//
//  AudioPlaybackHelpers.h
//  Moonlight
//
//  Pure helpers for audio IO duration, pending-ms, and queue vs PLC policy (testable).
//

#import <Foundation/Foundation.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

// Combined LBQ + SDL queued audio before skipping QueueAudio for a real packet.
static const int kMLAudioPendingCapMs = 20;

// Request an IO period matching the Opus frame, clamped to 2.5–10 ms.
FOUNDATION_EXPORT NSTimeInterval MLPreferredAudioIOBufferDuration(int sampleRate, int samplesPerFrame);

// SDL queued PCM duration. Truncates partial frames. Returns 0 if sizes are invalid.
FOUNDATION_EXPORT int MLSdlQueuedAudioDurationMs(unsigned int queuedBytes, int frameBytes, int packetDurationMs);

FOUNDATION_EXPORT int MLCombinedAudioPendingMs(int lbqDurationMs, int sdlDurationMs);

// Packet duration from Opus config. Falls back to 5 ms if rate/frame size is invalid.
FOUNDATION_EXPORT int MLAudioPacketDurationMs(int sampleRate, int samplesPerFrame);

// Always queue PLC. Queue real packets only when combined pending is within the cap.
FOUNDATION_EXPORT BOOL MLShouldQueueDecodedAudio(BOOL isPlc, int combinedPendingMs, int capMs);

// Normalize a saved audioConfig channel count to 2, 6, or 8 (stereo / 5.1 / 7.1).
FOUNDATION_EXPORT int MLNormalizedAudioChannelCount(int audioConfigChannels);

// Settings segment index: 0 = Stereo, 1 = 5.1, 2 = 7.1.
FOUNDATION_EXPORT int MLAudioConfigSegmentIndex(int audioConfigChannels);
FOUNDATION_EXPORT int MLAudioConfigChannelsForSegment(int segmentIndex);

// Map the Settings toggle to STREAM_CONFIGURATION.audioQuality
// (AUDIO_QUALITY_HIGH when YES, AUDIO_QUALITY_NORMAL when NO).
FOUNDATION_EXPORT int MLStreamAudioQualityMode(BOOL preferHighQuality);

NS_ASSUME_NONNULL_END
