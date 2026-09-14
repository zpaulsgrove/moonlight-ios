//
//  SoftDropHelpers.m
//  Moonlight
//

#import "SoftDropHelpers.h"

uint64_t MLSoftDropMaxAgeMs(int frameRate, BOOL networkPressureMode) {
    int fps = frameRate > 0 ? frameRate : 1;
    if (networkPressureMode) {
        // ~1.2 frame periods, never below 12 ms (avoids one-period thrash at 120 Hz).
        uint64_t ageMs = 1200ull / (uint64_t)fps;
        return ageMs < 12ull ? 12ull : ageMs;
    }
    uint64_t ageMs = 1500ull / (uint64_t)fps;
    return ageMs < 12ull ? 12ull : ageMs;
}

MLSoftDropDecision MLSoftDropEvaluate(BOOL isIdr,
                                      BOOL framePacing,
                                      BOOL cooldownActive,
                                      BOOL decodeChainBroken,
                                      BOOL rfiRecoveryPending,
                                      int frameNumber,
                                      int rfiSoftDroppedFrameNumber,
                                      int pendingFrames,
                                      uint64_t frameAgeMs,
                                      uint64_t maxAgeMs) {
    MLSoftDropDecision d = {0};
    
    // Prefer the newest frame only on the arrival-driven path. Soft-completing a skipped
    // P-frame never feeds it to the decoder, so reference chains break until IDR/RFI.
    // Frame pacing drains in decode order and must not soft-drop.
    BOOL overAge = frameAgeMs > maxAgeMs;
    d.dropForBacklog = !framePacing && !isIdr && !cooldownActive &&
                       pendingFrames >= kMLSoftDropPendingThreshold;
    // Never age-drop when pending is 0: after LiWaitForNextVideoFrame the waited frame is
    // already outside the queue, so an age-only drop would discard the only picture.
    d.dropForAge = !framePacing && !isIdr && !cooldownActive &&
                   pendingFrames >= 1 && overAge;
    d.dropBrokenChain = !isIdr && decodeChainBroken;
    
    d.rfiRecoveryCandidate = rfiRecoveryPending &&
                             !isIdr &&
                             frameNumber > rfiSoftDroppedFrameNumber;
    if (d.rfiRecoveryCandidate) {
        d.dropBrokenChain = NO;
        d.dropForAge = NO;
        d.dropForBacklog = NO;
    }
    
    d.drop = d.dropForBacklog || d.dropForAge || d.dropBrokenChain;
    return d;
}

BOOL MLPacedShouldKeepDraining(int enqueuedThisTick, int remainingQueued, int maxEnqueuesPerTick) {
    if (enqueuedThisTick < 1) {
        return YES;
    }
    if (remainingQueued <= 0) {
        return NO;
    }
    int cap = maxEnqueuesPerTick > 0 ? maxEnqueuesPerTick : kMLPacedMaxEnqueuesPerTick;
    return enqueuedThisTick < cap;
}

BOOL MLPacedShouldPollNextFrame(int enqueuedThisTick,
                                int remainingQueued,
                                int maxEnqueuesPerTick,
                                BOOL rendererReady) {
    if (!rendererReady) {
        return NO;
    }
    return MLPacedShouldKeepDraining(enqueuedThisTick, remainingQueued, maxEnqueuesPerTick);
}
