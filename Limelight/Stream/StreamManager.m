//
//  StreamManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamManager.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Utils.h"
#import "AbrController.h"
#import "AbrBitrateHelpers.h"
#import "NetworkPathMonitor.h"

#import "StreamView.h"
#import "ServerInfoResponse.h"
#import "HttpResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"

#include <Limelight.h>

#include <os/log.h>

@implementation StreamManager {
    StreamConfiguration* _config;

    UIView* _renderView;
    id<ConnectionCallbacks> _callbacks;
    Connection* _connection;
    VideoDecoderRenderer* _renderer;
    AbrController* _abrController;
}

- (id) initWithConfig:(StreamConfiguration*)config renderView:(UIView*)view connectionCallbacks:(id<ConnectionCallbacks>)callbacks {
    self = [super init];
    _config = config;
    _renderView = view;
    _callbacks = callbacks;
    _config.riKey = [Utils randomBytes:16];
    _config.riKeyId = arc4random();
    return self;
}

- (void)main {
    [CryptoManager generateKeyPairUsingSSL];
    
    HttpManager* hMan = [[HttpManager alloc] initWithAddress:_config.host httpsPort:_config.httpsPort
                                                     serverCert:_config.serverCert];
    
    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                       fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
    NSString* pairStatus = [serverInfoResp getStringTag:@"PairStatus"];
    NSString* appversion = [serverInfoResp getStringTag:@"appversion"];
    NSString* gfeVersion = [serverInfoResp getStringTag:@"GfeVersion"];
    NSString* serverState = [serverInfoResp getStringTag:@"state"];
    if (![serverInfoResp isStatusOk]) {
        [_callbacks launchFailed:serverInfoResp.statusMessage];
        return;
    }
    else if (pairStatus == NULL || appversion == NULL || serverState == NULL) {
        [_callbacks launchFailed:@"Failed to connect to PC"];
        return;
    }
    
    if (![pairStatus isEqualToString:@"1"]) {
        // Not paired
        [_callbacks launchFailed:@"Device not paired to PC"];
        return;
    }
    
    // Only perform this check on GFE (as indicated by MJOLNIR in state value)
    if ((_config.width > 4096 || _config.height > 4096) && [serverState containsString:@"MJOLNIR"]) {
        // Pascal added support for 8K HEVC encoding support. Maxwell 2 could encode HEVC but only up to 4K.
        // We can't directly identify Pascal, but we can look for HEVC Main10 which was added in the same generation.
        NSString* codecSupport = [serverInfoResp getStringTag:@"ServerCodecModeSupport"];
        if (codecSupport == nil || !([codecSupport intValue] & 0x200)) {
            [_callbacks launchFailed:@"Your host PC's GPU doesn't support streaming video resolutions over 4K."];
            return;
        }
    }
    
    // Prefer fresh ServerCodecModeSupport from this launch
    NSString* codecModeSupport = [serverInfoResp getStringTag:@"ServerCodecModeSupport"];
    if (codecModeSupport != nil) {
        _config.serverCodecModeSupport = [codecModeSupport intValue];
    }
    
    // Populate the config's version fields from serverinfo
    _config.appVersion = appversion;
    _config.gfeVersion = gfeVersion;
    
    // Warn clearly when HDR is requested but the host does not advertise Main10
    // (known Vibepollo / Sunshine advertisement bugs).
    if ((_config.supportedVideoFormats & VIDEO_FORMAT_MASK_10BIT) &&
        !(_config.serverCodecModeSupport & SCM_MASK_10BIT)) {
        Log(LOG_W, @"HDR enabled but host SCM lacks Main10 (0x%x); streaming without 10-bit formats",
            _config.serverCodecModeSupport);
        _config.supportedVideoFormats &= ~VIDEO_FORMAT_MASK_10BIT;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController* alert =
                [UIAlertController alertControllerWithTitle:@"HDR Unavailable"
                                                    message:@"HDR is enabled in settings, but this host did not advertise HEVC/AV1 Main10 support. Streaming in SDR. Check the host HDR / codec settings if this is unexpected."
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController* root = UIApplication.sharedApplication.keyWindow.rootViewController;
            while (root.presentedViewController) {
                root = root.presentedViewController;
            }
            [root presentViewController:alert animated:YES completion:nil];
        });
    }
    
    // resumeApp and launchApp handle calling launchFailed
    NSString* sessionUrl;
    if ([serverState hasSuffix:@"_SERVER_BUSY"]) {
        // App already running, resume it
        if (![self resumeApp:hMan receiveSessionUrl:&sessionUrl]) {
            return;
        }
    } else {
        // Start app
        if (![self launchApp:hMan receiveSessionUrl:&sessionUrl]) {
            return;
        }
    }
    
    // Populate RTSP session URL from launch/resume response
    _config.rtspSessionUrl = sessionUrl;
    
    // Initializing the renderer must be done on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        // Live path monitor for the stream session; Utils prefers it when hasPath is set.
        [[NetworkPathMonitor sharedMonitor] start];
        [Utils invalidateActiveNetworkWiFiCache];
        (void)[Utils isActiveNetworkWiFi];
        
        VideoDecoderRenderer* renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView callbacks:self->_callbacks streamAspectRatio:(float)self->_config.width / (float)self->_config.height useFramePacing:self->_config.useFramePacing];
        self->_renderer = renderer;
        self->_connection = [[Connection alloc] initWithConfig:self->_config renderer:renderer connectionCallbacks:self->_callbacks];
        self->_abrController = [[AbrController alloc] initWithConfig:self->_config connection:self->_connection];
        [self->_abrController attachRenderer:renderer];
        NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
        [opQueue addOperation:self->_connection];
        // Start ABR after the connection object exists; it probes the host asynchronously
        [self->_abrController start];
        
        static os_log_t perfLog;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            perfLog = os_log_create("com.moonlight-stream.Moonlight", "perf");
        });
        // Default level so lines persist into device log archives (Info often does not).
        os_log(perfLog,
                    "event=stream_start res=%{public}dx%{public}d fps=%{public}d bitrate=%{public}d pacing=%{public}d wifi=%{public}d hdrReq=%{public}d aggressivePkt=%{public}d lanClear=%{public}d",
                    self->_config.width,
                    self->_config.height,
                    self->_config.frameRate,
                    self->_config.bitRate,
                    self->_config.useFramePacing ? 1 : 0,
                    [Utils isActiveNetworkWiFi] ? 1 : 0,
                    (self->_config.supportedVideoFormats & VIDEO_FORMAT_MASK_10BIT) ? 1 : 0,
                    self->_config.aggressiveWifiPackets ? 1 : 0,
                    self->_config.disableEncryptionOnLan ? 1 : 0);
    });
}

- (void) stopStream
{
    [_abrController stop];
    _abrController = nil;
    [_connection terminate];
    _renderer = nil;
    [[NetworkPathMonitor sharedMonitor] stop];
}

- (void) connectionStatusUpdate:(int)status
{
    [_abrController noteConnectionStatus:status];
}

- (BOOL) launchApp:(HttpManager*)hMan receiveSessionUrl:(NSString**)sessionUrl {
    HttpResponse* launchResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:launchResp withUrlRequest:[hMan newLaunchOrResumeRequest:@"launch" config:_config]]];
    NSString *gameSession = [launchResp getStringTag:@"gamesession"];
    if (![launchResp isStatusOk]) {
        [_callbacks launchFailed:launchResp.statusMessage];
        Log(LOG_E, @"Failed Launch Response: %@", launchResp.statusMessage);
        return FALSE;
    } else if (gameSession == NULL || [gameSession isEqualToString:@"0"]) {
        [_callbacks launchFailed:@"Failed to launch app"];
        Log(LOG_E, @"Failed to parse game session");
        return FALSE;
    }
    
    *sessionUrl = [launchResp getStringTag:@"sessionUrl0"];
    return TRUE;
}

- (BOOL) resumeApp:(HttpManager*)hMan receiveSessionUrl:(NSString**)sessionUrl {
    HttpResponse* resumeResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resumeResp withUrlRequest:[hMan newLaunchOrResumeRequest:@"resume" config:_config]]];
    NSString* resume = [resumeResp getStringTag:@"resume"];
    if (![resumeResp isStatusOk]) {
        [_callbacks launchFailed:resumeResp.statusMessage];
        Log(LOG_E, @"Failed Resume Response: %@", resumeResp.statusMessage);
        return FALSE;
    } else if (resume == NULL || [resume isEqualToString:@"0"]) {
        [_callbacks launchFailed:@"Failed to resume app"];
        Log(LOG_E, @"Failed to parse resume response");
        return FALSE;
    }
    
    *sessionUrl = [resumeResp getStringTag:@"sessionUrl0"];
    return TRUE;
}

- (NSString*) getStatsOverlayTextForLevel:(MLStatsOverlayLevel)level {
    video_stats_t stats;
    
    if (level == MLStatsOverlayLevelOff || !_connection) {
        return nil;
    }
    
    if (![_connection getVideoStats:&stats]) {
        return nil;
    }
    
    uint32_t rtt = 0, variance = 0;
    BOOL hasRttEstimate = LiGetEstimatedRttInfo(&rtt, &variance);
    
    float interval = stats.endTime - stats.startTime;
    float framesPerSecond = MLStatsFramesPerSecond(stats.totalFrames, interval);
    // networkDroppedFrames / interval is a per-second rate, not the percentage the
    // label claims. Use the same ratio the adaptive bitrate controller acts on.
    float dropRatePercent = MLDropRatePercent(stats.networkDroppedFrames, stats.totalFrames);
    
    BOOL hasHostProcessingLatency = stats.framesWithHostProcessingLatency != 0;
    float averageHostProcessingLatency = hasHostProcessingLatency
        ? (float)stats.totalHostProcessingLatency / stats.framesWithHostProcessingLatency / 10.f
        : 0.f;
    
    BOOL hasClientQueueLatency = stats.framesWithClientQueueLatency != 0;
    float averageClientQueueLatency = hasClientQueueLatency
        ? (float)stats.totalClientQueueLatencyMs / (float)stats.framesWithClientQueueLatency
        : 0.f;
    
    if (level == MLStatsOverlayLevelLite) {
        MLStatsOverlaySample sample = {
            .width = _config.width,
            .height = _config.height,
            .videoFormat = [_connection getActiveVideoFormat],
            .hdrActive = LiGetCurrentHostDisplayHdrMode(),
            .framesPerSecond = framesPerSecond,
            .dropRatePercent = dropRatePercent,
            .hasRttEstimate = hasRttEstimate,
            .rttMs = rtt,
            .rttVarianceMs = variance,
            .hasHostProcessingLatency = hasHostProcessingLatency,
            .averageHostProcessingLatencyMs = averageHostProcessingLatency,
            .hasClientQueueLatency = hasClientQueueLatency,
            .averageClientQueueLatencyMs = averageClientQueueLatency,
        };
        return MLStatsOverlayLiteLine(sample);
    }
    
    NSString* latencyString;
    if (hasRttEstimate) {
        latencyString = [NSString stringWithFormat:@"%u ms (variance: %u ms)", rtt, variance];
    }
    else {
        latencyString = @"N/A";
    }
    
    NSString* hostProcessingString;
    if (hasHostProcessingLatency) {
        hostProcessingString = [NSString stringWithFormat:@"\nHost processing latency min/max/avg: %.1f/%.1f/%.1f ms",
                                stats.minHostProcessingLatency / 10.f,
                                stats.maxHostProcessingLatency / 10.f,
                                averageHostProcessingLatency];
    }
    else {
        hostProcessingString = @"";
    }
    
    NSString* clientQueueString;
    if (hasClientQueueLatency) {
        clientQueueString = [NSString stringWithFormat:@"\nClient queue latency min/max/avg: %.1f/%.1f/%.1f ms",
                             (float)stats.minClientQueueLatencyMs,
                             (float)stats.maxClientQueueLatencyMs,
                             averageClientQueueLatency];
    }
    else {
        clientQueueString = @"";
    }
    
    return [NSString stringWithFormat:@"Video stream: %dx%d %.2f FPS (Codec: %@)\nFrames dropped by your network connection: %.2f%%\nAverage network latency: %@%@%@",
            _config.width,
            _config.height,
            framesPerSecond,
            [_connection getActiveCodecName],
            dropRatePercent,
            latencyString,
            hostProcessingString,
            clientQueueString];
}

- (void)logPerfSample {
    if (!_connection) {
        return;
    }
    
    video_stats_t stats;
    if (![_connection getVideoStats:&stats]) {
        return;
    }
    
    uint32_t rtt = 0, variance = 0;
    BOOL hasRttEstimate = LiGetEstimatedRttInfo(&rtt, &variance);
    
    float interval = stats.endTime - stats.startTime;
    float framesPerSecond = MLStatsFramesPerSecond(stats.totalFrames, interval);
    float dropRatePercent = MLDropRatePercent(stats.networkDroppedFrames, stats.totalFrames);
    
    float hostMs = stats.framesWithHostProcessingLatency != 0
        ? (float)stats.totalHostProcessingLatency / stats.framesWithHostProcessingLatency / 10.f
        : -1.f;
    float hostMinMs = stats.framesWithHostProcessingLatency != 0
        ? stats.minHostProcessingLatency / 10.f
        : -1.f;
    float hostMaxMs = stats.framesWithHostProcessingLatency != 0
        ? stats.maxHostProcessingLatency / 10.f
        : -1.f;
    float queueMs = stats.framesWithClientQueueLatency != 0
        ? (float)stats.totalClientQueueLatencyMs / (float)stats.framesWithClientQueueLatency
        : -1.f;
    float queueMinMs = stats.framesWithClientQueueLatency != 0
        ? (float)stats.minClientQueueLatencyMs
        : -1.f;
    float queueMaxMs = stats.framesWithClientQueueLatency != 0
        ? (float)stats.maxClientQueueLatencyMs
        : -1.f;
    
    MLRendererPerfDelta delta = {0};
    [_renderer consumePerfDelta:&delta];
    
    NSInteger abrKbps = _abrController != nil ? [_abrController currentBitrateKbps] : _config.bitRate;
    int abrOn = (_abrController != nil && [_abrController isActive]) ? 1 : 0;
    
    static os_log_t perfLog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        perfLog = os_log_create("com.moonlight-stream.Moonlight", "perf");
    });
    
    // Greppable key=value line for Console / `log show` after a stream session.
    // host*/queue* use -1 when that window had no samples.
    os_log(perfLog,
                "fps=%.1f drop=%.2f dropN=%{public}d total=%{public}d recv=%{public}d net=%{public}d var=%{public}d host=%.1f hostMin=%.1f hostMax=%.1f queue=%.1f queueMin=%.1f queueMax=%.1f soft=%{public}llu softIdr=%{public}llu sat=%{public}llu idrNeed=%{public}llu idrOk=%{public}llu pendingMax=%{public}d abr=%{public}ld abrOn=%{public}d wifi=%{public}d res=%{public}dx%{public}d fmt=%{public}d hdr=%{public}d pacing=%{public}d",
                framesPerSecond,
                dropRatePercent,
                stats.networkDroppedFrames,
                stats.totalFrames,
                stats.receivedFrames,
                hasRttEstimate ? (int)rtt : -1,
                hasRttEstimate ? (int)variance : -1,
                hostMs,
                hostMinMs,
                hostMaxMs,
                queueMs,
                queueMinMs,
                queueMaxMs,
                (unsigned long long)delta.softDroppedFrames,
                (unsigned long long)delta.softDropIdrRequests,
                (unsigned long long)delta.saturatedDrops,
                (unsigned long long)delta.needsIdrResults,
                (unsigned long long)delta.idrEnqueued,
                delta.maxPendingFrames,
                (long)abrKbps,
                abrOn,
                [Utils isActiveNetworkWiFi] ? 1 : 0,
                _config.width,
                _config.height,
                [_connection getActiveVideoFormat],
                LiGetCurrentHostDisplayHdrMode() ? 1 : 0,
                _config.useFramePacing ? 1 : 0);
}

@end
