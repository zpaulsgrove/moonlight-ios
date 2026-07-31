//
//  AbrController.m
//  Moonlight
//
//  Local ABR driven by network drops / RTT variance via Vibepollo /bitrate.
//

#import "AbrController.h"
#import "HttpManager.h"
#import "Utils.h"
#import "AbrBitrateHelpers.h"

#include <Limelight.h>

@implementation AbrController {
    StreamConfiguration* _config;
    __weak Connection* _connection;
    HttpManager* _http;
    NSTimer* _timer;
    NSInteger _ceilingKbps;
    NSInteger _floorKbps;
    NSInteger _currentKbps;
    BOOL _supported;
    int _stableTicks;
}

- (instancetype)initWithConfig:(StreamConfiguration*)config
                    connection:(Connection*)connection {
    self = [super init];
    if (self) {
        _config = config;
        _connection = connection;
        _ceilingKbps = MAX(config.bitRate, 1000);
        _floorKbps = MAX((_ceilingKbps * 40) / 100, 1000);
        _currentKbps = _ceilingKbps;
        _http = [[HttpManager alloc] initWithAddress:config.host
                                           httpsPort:config.httpsPort
                                          serverCert:config.serverCert];
    }
    return self;
}

+ (NSInteger)clampBitrate:(NSInteger)candidate ceiling:(NSInteger)ceiling floor:(NSInteger)floor {
    return MLClampBitrate(candidate, ceiling, floor);
}

+ (NSInteger)nextBitrateFromCurrent:(NSInteger)current
                            ceiling:(NSInteger)ceiling
                              floor:(NSInteger)floor
                     dropRatePercent:(float)dropRatePercent
                        rttVarianceMs:(uint32_t)rttVarianceMs {
    return MLNextAbrBitrate(current, ceiling, floor, dropRatePercent, rttVarianceMs);
}

- (void)start {
    // Default-on for non-VPN sessions when the host exposes ABR capabilities
    if ([Utils isActiveNetworkVPN]) {
        Log(LOG_I, @"ABR disabled on VPN path");
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = [self->_http probeAbrCapabilities];
        if (!ok) {
            Log(LOG_I, @"ABR unavailable on host (no /api/abr/capabilities)");
            return;
        }
        
        self->_supported = YES;
        Log(LOG_I, @"ABR enabled (local controller, ceiling %ld kbps, floor %ld kbps)",
            (long)self->_ceilingKbps, (long)self->_floorKbps);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                            target:self
                                                          selector:@selector(tick)
                                                          userInfo:nil
                                                           repeats:YES];
        });
    });
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
}

- (void)tick {
    if (!_supported) {
        return;
    }
    
    Connection* connection = _connection;
    if (connection == nil) {
        return;
    }
    
    video_stats_t stats;
    if (![connection getVideoStats:&stats]) {
        return;
    }
    
    float interval = (float)(stats.endTime - stats.startTime);
    if (interval <= 0.1f) {
        return;
    }
    
    float dropRatePercent = (stats.networkDroppedFrames / interval);
    uint32_t rtt = 0, variance = 0;
    LiGetEstimatedRttInfo(&rtt, &variance);
    
    NSInteger next = MLNextAbrBitrate(_currentKbps, _ceilingKbps, _floorKbps, dropRatePercent, variance);
    
    if (next == _currentKbps) {
        _stableTicks++;
        return;
    }
    
    // Avoid tiny jittery adjustments
    if (labs(next - _currentKbps) < MAX(_ceilingKbps / 100, 500) && dropRatePercent < 2.0f) {
        return;
    }
    
    NSInteger target = next;
    _currentKbps = target;
    _stableTicks = 0;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL applied = [self->_http setStreamBitrateKbps:target];
        if (applied) {
            Log(LOG_I, @"ABR set bitrate to %ld kbps (drops=%.2f%% rttVar=%u)",
                (long)target, dropRatePercent, variance);
        }
    });
}

@end
