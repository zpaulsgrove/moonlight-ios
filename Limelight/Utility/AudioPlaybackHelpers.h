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

NS_ASSUME_NONNULL_END
