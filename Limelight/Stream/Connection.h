//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "StreamConfiguration.h"

#define CONN_TEST_SERVER "ios.conntest.moonlight-stream.org"

typedef struct {
    CFTimeInterval startTime;
    CFTimeInterval endTime;
    int totalFrames;
    int receivedFrames;
    int networkDroppedFrames;
    int totalHostProcessingLatency;
    int framesWithHostProcessingLatency;
    int maxHostProcessingLatency;
    int minHostProcessingLatency;
    // Sum of (submitTime - decodeUnit.enqueueTime) over frames that entered submitFrame.
    // This is client queue wait only, not decode or display.
    uint64_t totalClientQueueLatencyMs;
    int framesWithClientQueueLatency;
    uint64_t minClientQueueLatencyMs;
    uint64_t maxClientQueueLatencyMs;
} video_stats_t;

@interface Connection : NSOperation <NSStreamDelegate>

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
-(void) terminate;
-(void) main;
-(BOOL) getVideoStats:(video_stats_t*)stats;
-(NSString*) getActiveCodecName;
// Negotiated VIDEO_FORMAT_* value from decoder setup, or 0 before the first frame.
-(int) getActiveVideoFormat;

@end

// Called on the submission thread for every waited/polled frame. Records client queue wait
// (LiGetMillis() - decodeUnit.enqueueTimeMs) into the current 0.5s video stats window.
FOUNDATION_EXPORT void DrNoteClientQueueAgeMs(uint64_t ageMs);
