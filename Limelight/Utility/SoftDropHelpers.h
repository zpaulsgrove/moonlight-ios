//
//  SoftDropHelpers.h
//  Moonlight
//
//  Pure helpers for late-frame / soft-drop age gates and drop decisions (testable).
//
//  RFI soft-drop recovery (VideoDecoderRenderer) calls:
//    bool LiIsReferenceFrameInvalidationEnabled(void);
//    void LiNotifyClientDroppedFrames(uint32_t startFrame, uint32_t endFrame);
//  when Limelight.h exports them. If those symbols are missing, keep DR_NEED_IDR only.
//

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Soft-drop pending threshold: a single queued frame is normal at high refresh.
static const int kMLSoftDropPendingThreshold = 2;

// Paced catch-up: enqueue at most this many decoded samples per vsync so a
// refresh dip cannot dump the whole depacketizer FIFO into ASBDL at once.
static const int kMLPacedMaxEnqueuesPerTick = 4;

// Roughly 1.5 frame periods, floored at 12 ms: MAX(12, 1500 / MAX(frameRate, 1)).
// Under network pressure, tighten slightly but keep at least ~1.2 periods with a 12 ms
// floor so 120 Hz does not age-drop every one-frame stall.
FOUNDATION_EXPORT uint64_t MLSoftDropMaxAgeMs(int frameRate, BOOL networkPressureMode);

typedef struct {
    BOOL dropForBacklog;
    BOOL dropForAge;
    BOOL dropBrokenChain;
    BOOL drop;
    BOOL rfiRecoveryCandidate;
} MLSoftDropDecision;

// Arrival-path soft-drop policy. Frame pacing never soft-drops (decode order).
// Cooldown blocks starting a new backlog/age streak after IDR recovery.
// Age drops require pendingFrames >= 1 so the sole waited frame is not discarded.
// RFI recovery candidates suppress backlog/age/broken drops so a later frame can enqueue.
FOUNDATION_EXPORT MLSoftDropDecision MLSoftDropEvaluate(BOOL isIdr,
                                                        BOOL framePacing,
                                                        BOOL cooldownActive,
                                                        BOOL decodeChainBroken,
                                                        BOOL rfiRecoveryPending,
                                                        int frameNumber,
                                                        int rfiSoftDroppedFrameNumber,
                                                        int pendingFrames,
                                                        uint64_t frameAgeMs,
                                                        uint64_t maxAgeMs);

// After a successful paced enqueue, keep polling if more frames remain and this
// vsync is still under the flood cap. Drain toward the live edge (remaining 0)
// rather than holding a multi-frame backlog across ticks.
FOUNDATION_EXPORT BOOL MLPacedShouldKeepDraining(int enqueuedThisTick,
                                                 int remainingQueued,
                                                 int maxEnqueuesPerTick);

NS_ASSUME_NONNULL_END
