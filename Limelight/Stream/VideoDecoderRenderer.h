//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"

#include "Limelight.h"
#include <stdint.h>

// Outcome of a single submission attempt. Both submission drivers (the arrival-driven render
// thread and the frame-pacing display link) read this instead of a shared boolean side channel.
typedef NS_ENUM(NSInteger, MLEnqueueResult) {
    MLEnqueueResultEnqueued,  // the sample reached the video renderer
    MLEnqueueResultDropped,   // deliberately not enqueued; safe to complete as DR_OK
    MLEnqueueResultNeedsIdr,  // could not be enqueued; the stream needs a fresh keyframe
};

// Delta counters since the last consume call. Used by StreamManager's 1 Hz perf sample.
typedef struct {
    uint64_t softDroppedFrames;
    uint64_t softDropIdrRequests;
    uint64_t saturatedDrops;
    uint64_t needsIdrResults;
    uint64_t idrEnqueued;
    int maxPendingFrames;
} MLRendererPerfDelta;

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;

// Takes an immutable HDR snapshot captured on the caller's thread. Pass NULL for metadata when
// the host reported none. The snapshot is applied on whichever thread drives submission.
- (void)setHdrMode:(BOOL)enabled metadata:(const SS_HDR_METADATA*)metadata;

- (MLEnqueueResult)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

// Atomically copies and clears the delta window used for os_log category "perf" samples.
- (void)consumePerfDelta:(MLRendererPerfDelta *)outDelta;

@end
