//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Connection.h"
#import "StatsOverlayFormatting.h"

@interface StreamManager : NSOperation

- (id) initWithConfig:(StreamConfiguration*)config renderView:(UIView*)view connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;

// Forward CONN_STATUS_* into the ABR / local-pressure controller.
- (void) connectionStatusUpdate:(int)status;

- (NSString*) getStatsOverlayTextForLevel:(MLStatsOverlayLevel)level;

// Emits one structured os_log line (subsystem com.moonlight-stream.Moonlight, category perf)
// with Lite fields plus soft-drop/ABR deltas for later device log collection. Rare events use
// the same category with an event= prefix.
- (void) logPerfSample;

@end
