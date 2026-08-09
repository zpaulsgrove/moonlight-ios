//
//  AbrController.h
//  Moonlight
//
//  Local adaptive bitrate controller for Vibepollo /bitrate.
//

#import <Foundation/Foundation.h>
#import "Connection.h"
#import "StreamConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface AbrController : NSObject

// Ceiling is the user-selected bitrate (kbps). Floor is ~40% of ceiling.
// Probes /api/abr/capabilities; no-ops cleanly if the host lacks the endpoint.
- (instancetype)initWithConfig:(StreamConfiguration*)config
                    connection:(Connection*)connection;

- (void)start;
- (void)stop;

// YES after the host advertised ABR support and the tick timer is running.
- (BOOL)isActive;
// Last applied (or initial) target bitrate in kbps. Meaningful even before isActive.
- (NSInteger)currentBitrateKbps;

// Pure helper for tests: clamp a candidate bitrate into [floor, ceiling].
+ (NSInteger)clampBitrate:(NSInteger)candidate ceiling:(NSInteger)ceiling floor:(NSInteger)floor;

// Pure helper for tests: next bitrate from drop rate / RTT variance.
+ (NSInteger)nextBitrateFromCurrent:(NSInteger)current
                            ceiling:(NSInteger)ceiling
                              floor:(NSInteger)floor
                     dropRatePercent:(float)dropRatePercent
                        rttVarianceMs:(uint32_t)rttVarianceMs;

@end

NS_ASSUME_NONNULL_END
