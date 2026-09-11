//
//  AbrController.h
//  Moonlight
//
//  Local adaptive bitrate controller for Vibepollo /bitrate.
//

#import <Foundation/Foundation.h>
#import "Connection.h"
#import "StreamConfiguration.h"

@class VideoDecoderRenderer;

NS_ASSUME_NONNULL_BEGIN

@interface AbrController : NSObject

// Ceiling is the user-selected bitrate (kbps). Floor is ~40% of ceiling.
// Host ABR (Vibepollo /bitrate) is used when available; otherwise local pressure fallback.
- (instancetype)initWithConfig:(StreamConfiguration*)config
                    connection:(Connection*)connection;

- (void)attachRenderer:(VideoDecoderRenderer*)renderer;

- (void)start;
- (void)stop;

// Forwarded from CONN_STATUS_* callbacks.
- (void)noteConnectionStatus:(int)status;

// YES when Vibepollo host ABR apply path is active.
- (BOOL)isActive;
// Last applied (or shadow) target bitrate in kbps.
- (NSInteger)currentBitrateKbps;

// Pure helper for tests: clamp a candidate bitrate into [floor, ceiling].
+ (NSInteger)clampBitrate:(NSInteger)candidate ceiling:(NSInteger)ceiling floor:(NSInteger)floor;

// Pure helper for tests: next bitrate from drop / RTT / FEC / queue / poor.
+ (NSInteger)nextBitrateFromCurrent:(NSInteger)current
                            ceiling:(NSInteger)ceiling
                              floor:(NSInteger)floor
                     dropRatePercent:(float)dropRatePercent
                        rttVarianceMs:(uint32_t)rttVarianceMs
                 fecRepairRatePercent:(float)fecRepairRatePercent
                       queueLatencyMs:(float)queueLatencyMs
                       connectionPoor:(BOOL)connectionPoor;

@end

NS_ASSUME_NONNULL_END
