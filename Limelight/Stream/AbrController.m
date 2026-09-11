//
//  AbrController.m
//  Moonlight
//
//  Local ABR driven by network drops / RTT / FEC / queue latency.
//  Applies via Vibepollo /bitrate when available; otherwise drives renderer pressure.
//

#import "AbrController.h"
#import "HttpManager.h"
#import "Utils.h"
#import "AbrBitrateHelpers.h"
#import "NetworkPathMonitor.h"
#import "VideoDecoderRenderer.h"

#include <Limelight.h>
#include <os/log.h>
#import <QuartzCore/QuartzCore.h>

static os_log_t AbrPerfLog(void)
{
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.moonlight-stream.Moonlight", "perf");
    });
    return log;
}

@implementation AbrController {
    StreamConfiguration* _config;
    __weak Connection* _connection;
    __weak VideoDecoderRenderer* _renderer;
    HttpManager* _http;
    NSTimer* _timer;
    NSInteger _ceilingKbps;
    NSInteger _floorKbps;
    NSInteger _currentKbps;
    BOOL _hostAbrSupported;
    BOOL _localAdaptationActive;
    BOOL _connectionPoor;
    BOOL _pathConstrained;
    BOOL _pathHoldActive;
    CFTimeInterval _pathHoldUntil;
    NSInteger _generation;
    BOOL _applyInFlight;
    uint32_t _lastFecRecoveredFrames;
    BOOL _hasFecBaseline;
    uint64_t _lastBytesReceived;
    CFTimeInterval _lastBytesAt;
    BOOL _hasBytesBaseline;
}

- (instancetype)initWithConfig:(StreamConfiguration*)config
                    connection:(Connection*)connection {
    self = [super init];
    if (self) {
        _config = config;
        _connection = connection;
        _ceilingKbps = MAX(config.bitRate, 1000);
        _floorKbps = MAX((_ceilingKbps * 40) / 100, 1000);
        _currentKbps = MLAbrInitialKbps(_ceilingKbps, _floorKbps, [Utils isActiveNetworkWiFi]);
        _http = [[HttpManager alloc] initWithAddress:config.host
                                           httpsPort:config.httpsPort
                                          serverCert:config.serverCert];
    }
    return self;
}

- (void)attachRenderer:(VideoDecoderRenderer*)renderer {
    _renderer = renderer;
}

+ (NSInteger)clampBitrate:(NSInteger)candidate ceiling:(NSInteger)ceiling floor:(NSInteger)floor {
    return MLClampBitrate(candidate, ceiling, floor);
}

+ (NSInteger)nextBitrateFromCurrent:(NSInteger)current
                            ceiling:(NSInteger)ceiling
                              floor:(NSInteger)floor
                     dropRatePercent:(float)dropRatePercent
                        rttVarianceMs:(uint32_t)rttVarianceMs
                 fecRepairRatePercent:(float)fecRepairRatePercent
                       queueLatencyMs:(float)queueLatencyMs
                       connectionPoor:(BOOL)connectionPoor {
    return MLNextAbrBitrate(current, ceiling, floor, dropRatePercent, rttVarianceMs,
                            fecRepairRatePercent, queueLatencyMs, connectionPoor);
}

- (void)noteConnectionStatus:(int)status {
    BOOL poor = (status == CONN_STATUS_POOR);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_connectionPoor = poor;
    });
}

- (void)start {
    if ([Utils isActiveNetworkVPN]) {
        Log(LOG_I, @"ABR disabled on VPN path");
        return;
    }
    
    NSInteger gen = _generation;
    NetworkPathMonitor *pathMonitor = [NetworkPathMonitor sharedMonitor];
    _pathConstrained = pathMonitor.hasPath && (pathMonitor.isConstrained || pathMonitor.isExpensive);
    _pathHoldActive = _pathConstrained;
    _pathHoldUntil = _pathConstrained ? CACurrentMediaTime() + MLAbrPathHintHoldDuration : 0;
    __weak AbrController *weakSelf = self;
    [pathMonitor addObserver:self handler:^(NetworkPathMonitor *monitor) {
        BOOL constrained = monitor.isConstrained || monitor.isExpensive;
        dispatch_async(dispatch_get_main_queue(), ^{
            AbrController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_pathConstrained = constrained;
        });
    }];
    
    // Local adaptation always runs (host apply is optional).
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gen != self->_generation) {
            return;
        }
        self->_localAdaptationActive = YES;
        [self->_timer invalidate];
        self->_timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(tick)
                                                      userInfo:nil
                                                       repeats:YES];
    });
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (gen != self->_generation) {
            return;
        }
        
        BOOL ok = [self->_http probeAbrCapabilities];
        if (!ok) {
            Log(LOG_I, @"Host ABR unavailable; using local pressure fallback");
            return;
        }
        
        if (gen != self->_generation) {
            return;
        }
        
        Log(LOG_I, @"Host ABR enabled (ceiling %ld kbps, floor %ld kbps)",
            (long)self->_ceilingKbps, (long)self->_floorKbps);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_generation) {
                return;
            }
            self->_hostAbrSupported = YES;
        });
    });
}

- (void)stop {
    // Generation bump is synchronous so in-flight work drops immediately.
    _generation++;
    _hostAbrSupported = NO;
    _localAdaptationActive = NO;
    _applyInFlight = NO;
    _connectionPoor = NO;
    _pathConstrained = NO;
    _pathHoldActive = NO;
    _pathHoldUntil = 0;
    _hasFecBaseline = NO;
    _hasBytesBaseline = NO;
    [[NetworkPathMonitor sharedMonitor] removeObserver:self];
    
    // NSTimer must be invalidated on the run-loop thread that owns it (main).
    void (^teardownOnMain)(void) = ^{
        VideoDecoderRenderer *renderer = self->_renderer;
        renderer.networkPressureMode = NO;
        [self->_timer invalidate];
        self->_timer = nil;
    };
    if ([NSThread isMainThread]) {
        teardownOnMain();
    }
    else {
        dispatch_async(dispatch_get_main_queue(), teardownOnMain);
    }
}

- (BOOL)isActive {
    return _hostAbrSupported;
}

- (NSInteger)currentBitrateKbps {
    return _currentKbps;
}

- (void)updatePressure:(BOOL)pressure {
    VideoDecoderRenderer *renderer = _renderer;
    if (renderer != nil && renderer.networkPressureMode != pressure) {
        renderer.networkPressureMode = pressure;
        os_log(AbrPerfLog(), "event=abr_pressure on=%{public}d hostAbr=%{public}d",
               pressure ? 1 : 0, _hostAbrSupported ? 1 : 0);
    }
}

- (void)tick {
    if (!_localAdaptationActive) {
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
    
    float dropRatePercent = MLDropRatePercent(stats.networkDroppedFrames, stats.totalFrames);
    float queueLatencyMs = MLAvgQueueLatencyMs(stats.totalClientQueueLatencyMs,
                                               stats.framesWithClientQueueLatency);
    
    uint32_t rtt = 0, variance = 0;
    LiGetEstimatedRttInfo(&rtt, &variance);
    
    float fecRepairRatePercent = 0.0f;
    uint32_t fecRecoveredPackets = 0, fecRecoveredFrames = 0, fecFailedFrames = 0;
    if (LiGetVideoFecStats(&fecRecoveredPackets, &fecRecoveredFrames, &fecFailedFrames)) {
        if (_hasFecBaseline) {
            uint32_t deltaRecovered = 0;
            if (fecRecoveredFrames >= _lastFecRecoveredFrames) {
                deltaRecovered = fecRecoveredFrames - _lastFecRecoveredFrames;
            }
            fecRepairRatePercent = MLFecRepairRatePercent(deltaRecovered, (uint32_t)MAX(stats.totalFrames, 0));
        }
        _lastFecRecoveredFrames = fecRecoveredFrames;
        _hasFecBaseline = YES;
    }
    
    double goodputKbps = -1.0;
    uint64_t bytesReceived = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (LiGetVideoBytesReceived(&bytesReceived)) {
        if (_hasBytesBaseline && now > _lastBytesAt) {
            double dt = now - _lastBytesAt;
            if (dt >= 0.2 && bytesReceived >= _lastBytesReceived) {
                goodputKbps = ((double)(bytesReceived - _lastBytesReceived) * 8.0 / 1000.0) / dt;
            }
        }
        _lastBytesReceived = bytesReceived;
        _lastBytesAt = now;
        _hasBytesBaseline = YES;
    }
    
    // Hard poor is loss/status evidence only. Path constrained/expensive is a soft hint.
    BOOL hardPoor = _connectionPoor;
    if (goodputKbps >= 0.0 && _currentKbps > 0 &&
        goodputKbps < (double)_currentKbps * 0.50 && dropRatePercent > 0.5f) {
        hardPoor = YES;
    }
    
    NSInteger next = MLNextAbrBitrate(_currentKbps, _ceilingKbps, _floorKbps,
                                      dropRatePercent, variance,
                                      fecRepairRatePercent, queueLatencyMs, hardPoor);
    // Soft path hint expires after MLAbrPathHintHoldDuration once constrained clears.
    next = MLAbrApplyPathHintEx(next, _currentKbps, _pathConstrained,
                                &_pathHoldActive, &_pathHoldUntil, now,
                                MLAbrPathHintHoldDuration);
    
    BOOL wantsCut = next < _currentKbps;
    // Always refresh pressure, including while a host apply is in flight.
    [self updatePressure:MLAbrWantsNetworkPressure(wantsCut, hardPoor)];
    
    if (_applyInFlight) {
        return;
    }
    
    if (next == _currentKbps) {
        return;
    }
    
    // Avoid tiny jittery adjustments
    if (labs(next - _currentKbps) < MAX(_ceilingKbps / 100, 500) && dropRatePercent < 2.0f && !hardPoor) {
        return;
    }
    
    if (!_hostAbrSupported) {
        // Shadow bitrate for overlay/stats; host cannot be retargeted without ABR API.
        NSInteger prev = _currentKbps;
        _currentKbps = next;
        Log(LOG_I, @"Local ABR shadow %ld -> %ld kbps (drops=%.2f%% fec=%.2f%% q=%.1f poor=%d path=%d)",
            (long)prev, (long)next, dropRatePercent, fecRepairRatePercent, queueLatencyMs,
            hardPoor ? 1 : 0, _pathConstrained ? 1 : 0);
        os_log(AbrPerfLog(),
               "event=abr_local kbps=%{public}ld prev=%{public}ld drop=%.2f fec=%.2f q=%.1f var=%{public}u poor=%{public}d path=%{public}d goodput=%.0f",
               (long)next, (long)prev, dropRatePercent, fecRepairRatePercent, queueLatencyMs,
               variance, hardPoor ? 1 : 0, _pathConstrained ? 1 : 0, goodputKbps);
        return;
    }
    
    NSInteger target = next;
    NSInteger gen = _generation;
    _applyInFlight = YES;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL applied = [self->_http setStreamBitrateKbps:target];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_generation) {
                return;
            }
            self->_applyInFlight = NO;
            if (applied) {
                NSInteger prev = self->_currentKbps;
                self->_currentKbps = target;
                Log(LOG_I, @"ABR set bitrate to %ld kbps (drops=%.2f%% fec=%.2f%% q=%.1f rttVar=%u)",
                    (long)target, dropRatePercent, fecRepairRatePercent, queueLatencyMs, variance);
                os_log(AbrPerfLog(),
                       "event=abr kbps=%{public}ld prev=%{public}ld drop=%.2f fec=%.2f q=%.1f var=%{public}u goodput=%.0f",
                       (long)target, (long)prev, dropRatePercent, fecRepairRatePercent,
                       queueLatencyMs, variance, goodputKbps);
            }
            else {
                Log(LOG_W, @"ABR bitrate apply failed for %ld kbps; keeping %ld kbps",
                    (long)target, (long)self->_currentKbps);
            }
        });
    });
}

@end
