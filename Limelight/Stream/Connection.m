//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Utils.h"
#import "NetworkPathMonitor.h"
#import "AudioPlaybackHelpers.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#define SDL_MAIN_HANDLED
#import <SDL.h>

#include "Limelight.h"
#include "opus_multistream.h"

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[128];
}

static NSLock* initLock;
static OpusMSDecoder* opusDecoder;
static id<ConnectionCallbacks> _callbacks;
static int lastFrameNumber;
static int activeVideoFormat;
static video_stats_t currentVideoStats;
static video_stats_t lastVideoStats;
static NSLock* videoStatsLock;

static SDL_AudioDeviceID audioDevice;
static OPUS_MULTISTREAM_CONFIGURATION audioConfig;
static void* audioBuffer;
static int audioFrameSize;

static VideoDecoderRenderer* renderer;

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat width:width height:height frameRate:redrawRate];
    lastFrameNumber = 0;
    activeVideoFormat = videoFormat;
    memset(&currentVideoStats, 0, sizeof(currentVideoStats));
    memset(&lastVideoStats, 0, sizeof(lastVideoStats));
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStop(void)
{
    [renderer stop];
}

-(BOOL) getVideoStats:(video_stats_t*)stats
{
    // We return lastVideoStats because it is a complete stats window
    [videoStatsLock lock];
    if (lastVideoStats.endTime != 0) {
        memcpy(stats, &lastVideoStats, sizeof(*stats));
        [videoStatsLock unlock];
        return YES;
    }
    
    // No stats yet
    [videoStatsLock unlock];
    return NO;
}

-(int) getActiveVideoFormat
{
    return activeVideoFormat;
}

void DrNoteClientQueueAgeMs(uint64_t ageMs)
{
    // Submission thread only, same writer as DrSubmitDecodeUnit's currentVideoStats updates.
    if (currentVideoStats.framesWithClientQueueLatency == 0 ||
        ageMs < currentVideoStats.minClientQueueLatencyMs) {
        currentVideoStats.minClientQueueLatencyMs = ageMs;
    }
    if (ageMs > currentVideoStats.maxClientQueueLatencyMs) {
        currentVideoStats.maxClientQueueLatencyMs = ageMs;
    }
    currentVideoStats.totalClientQueueLatencyMs += ageMs;
    currentVideoStats.framesWithClientQueueLatency++;
}

-(NSString*) getActiveCodecName
{
    switch (activeVideoFormat)
    {
        case VIDEO_FORMAT_H264:
            return @"H.264";
        case VIDEO_FORMAT_H265:
            return @"HEVC";
        case VIDEO_FORMAT_H265_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"HEVC Main 10 HDR";
            }
            else {
                return @"HEVC Main 10 SDR";
            }
        case VIDEO_FORMAT_AV1_MAIN8:
            return @"AV1";
        case VIDEO_FORMAT_AV1_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"AV1 10-bit HDR";
            }
            else {
                return @"AV1 10-bit SDR";
            }
        default:
            return @"UNKNOWN";
    }
}

MLEnqueueResult DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    MLEnqueueResult ret;
    
    CFTimeInterval now = CACurrentMediaTime();
    if (!lastFrameNumber) {
        currentVideoStats.startTime = now;
        lastFrameNumber = decodeUnit->frameNumber;
    }
    else {
        // Flip stats every 0.5s so ABR sees fresher drop%
        if (now - currentVideoStats.startTime >= 0.5f) {
            currentVideoStats.endTime = now;
            
            [videoStatsLock lock];
            lastVideoStats = currentVideoStats;
            [videoStatsLock unlock];
            
            memset(&currentVideoStats, 0, sizeof(currentVideoStats));
            currentVideoStats.startTime = now;
        }
        
        // Any frame number greater than m_LastFrameNumber + 1 represents a dropped frame
        currentVideoStats.networkDroppedFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        currentVideoStats.totalFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        lastFrameNumber = decodeUnit->frameNumber;
    }
    
    if (decodeUnit->frameHostProcessingLatency != 0) {
        if (currentVideoStats.minHostProcessingLatency == 0 || decodeUnit->frameHostProcessingLatency < currentVideoStats.minHostProcessingLatency) {
            currentVideoStats.minHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        if (decodeUnit->frameHostProcessingLatency > currentVideoStats.maxHostProcessingLatency) {
            currentVideoStats.maxHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        currentVideoStats.framesWithHostProcessingLatency++;
        currentVideoStats.totalHostProcessingLatency += decodeUnit->frameHostProcessingLatency;
    }
    
    currentVideoStats.receivedFrames++;
    currentVideoStats.totalFrames++;

    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        // Submit parameter set NALUs directly since no copy is required by the decoder
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            ret = [renderer submitDecodeBuffer:(unsigned char*)entry->data
                                        length:entry->length
                                    bufferType:entry->bufferType
                                     decodeUnit:decodeUnit];
            if (ret == MLEnqueueResultNeedsIdr) {
                return ret;
            }
        }
        entry = entry->next;
    }

    // Gather PICDATA once into a CMBlockBuffer inside the renderer (no intermediate assembly copy).
    return [renderer submitDecodeBuffer:NULL
                                 length:0
                             bufferType:BUFFER_TYPE_PICDATA
                             decodeUnit:decodeUnit];
}

static BOOL MLSetPreferredIOBufferDuration(AVAudioSession *session, NSTimeInterval preferredIOBufferDuration)
{
    NSError *error = nil;
    if ([session setPreferredIOBufferDuration:preferredIOBufferDuration error:&error]) {
        return YES;
    }
    Log(LOG_W, @"AVAudioSession preferredIOBufferDuration %.4fs failed: %@",
        preferredIOBufferDuration, error.localizedDescription);
    
    // Frame-sized requests can be rejected on some devices; fall back to 5 ms once.
    const NSTimeInterval kFallbackIO = 0.005;
    if (preferredIOBufferDuration > kFallbackIO + 0.0001) {
        error = nil;
        if ([session setPreferredIOBufferDuration:kFallbackIO error:&error]) {
            Log(LOG_W, @"AVAudioSession fell back to 5 ms IO period");
            return YES;
        }
        Log(LOG_W, @"AVAudioSession 5 ms IO fallback failed: %@", error.localizedDescription);
    }
    return NO;
}

static void MLApplyLowLatencyAudioSession(NSTimeInterval preferredIOBufferDuration)
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    // There is no AVAudioSessionModeGame. Default plus a frame-sized IO period is the
    // low-latency playback path. Measurement would also shrink processing but lowers output level.
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error]) {
        Log(LOG_W, @"AVAudioSession category/mode failed: %@", error.localizedDescription);
    }
    (void)MLSetPreferredIOBufferDuration(session, preferredIOBufferDuration);
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int flags)
{
    int err;
    SDL_AudioSpec want, have;
    NSTimeInterval preferredIO = MLPreferredAudioIOBufferDuration(opusConfig->sampleRate,
                                                                  opusConfig->samplesPerFrame);
    
    // Session must be configured before SDL opens the device so Core Audio picks the IO period.
    MLApplyLowLatencyAudioSession(preferredIO);
    SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "playback");
    
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) {
        Log(LOG_E, @"Failed to initialize audio subsystem: %s\n", SDL_GetError());
        return -1;
    }
        
    SDL_zero(want);
    want.freq = opusConfig->sampleRate;
    want.format = AUDIO_S16;
    want.channels = opusConfig->channelCount;
    want.samples = opusConfig->samplesPerFrame;

    audioDevice = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (audioDevice == 0) {
        Log(LOG_E, @"Failed to open audio device: %s\n", SDL_GetError());
        ArCleanup();
        return -1;
    }
    
    audioConfig = *opusConfig;
    audioFrameSize = opusConfig->samplesPerFrame * sizeof(short) * opusConfig->channelCount;
    audioBuffer = SDL_malloc(audioFrameSize);
    if (audioBuffer == NULL) {
        Log(LOG_E, @"Failed to allocate audio frame buffer");
        ArCleanup();
        return -1;
    }
    
    opusDecoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                  opusConfig->channelCount,
                                                  opusConfig->streams,
                                                  opusConfig->coupledStreams,
                                                  opusConfig->mapping,
                                                  &err);
    if (opusDecoder == NULL) {
        Log(LOG_E, @"Failed to create Opus decoder");
        ArCleanup();
        return -1;
    }
    
    // Start playback
    SDL_PauseAudioDevice(audioDevice, 0);
    
    // SDL may reset category/options on open; re-apply MixWithOthers and the IO period.
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (error != nil) {
        Log(LOG_W, @"AVAudioSession re-apply after SDL open failed: %@", error.localizedDescription);
    }
    (void)MLSetPreferredIOBufferDuration(session, preferredIO);
    
    NSTimeInterval actualIO = session.IOBufferDuration;
    Log(LOG_I, @"Audio device want.samples=%d have.samples=%d preferredIO=%.4fs actualIO=%.4fs channels=%d streams=%d coupled=%d",
        want.samples,
        have.samples,
        preferredIO,
        actualIO,
        opusConfig->channelCount,
        opusConfig->streams,
        opusConfig->coupledStreams);
    if (actualIO > preferredIO + 0.002) {
        Log(LOG_E, @"AVAudioSession IOBufferDuration still high (%.4fs vs preferred %.4fs)",
            actualIO, preferredIO);
    }
    
    return 0;
}

void ArCleanup(void)
{
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
    
    if (audioDevice != 0) {
        SDL_CloseAudioDevice(audioDevice);
        audioDevice = 0;
    }
    
    if (audioBuffer != NULL) {
        SDL_free(audioBuffer);
        audioBuffer = NULL;
    }
    
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    int decodeLen;
    BOOL isPlc = (sampleData == NULL || sampleLength <= 0);
    int packetMs = MLAudioPacketDurationMs(audioConfig.sampleRate, audioConfig.samplesPerFrame);
    unsigned int queuedBytes = (audioDevice != 0) ? SDL_GetQueuedAudioSize(audioDevice) : 0;
    int sdlMs = MLSdlQueuedAudioDurationMs(queuedBytes, audioFrameSize, packetMs);
    int pendingMs = MLCombinedAudioPendingMs(LiGetPendingAudioDuration(), sdlMs);
    
    // Always decode (including PLC) so Opus state stays in lockstep. Skip QueueAudio
    // only for surplus real packets so the cap cannot drop concealment.
    decodeLen = opus_multistream_decode(opusDecoder, (unsigned char *)sampleData, sampleLength,
                                        (short*)audioBuffer, audioConfig.samplesPerFrame, 0);
    if (decodeLen < 0) {
        Log(LOG_W, @"Opus decode failed: %d plc=%d", decodeLen, isPlc ? 1 : 0);
        // Corrupt real packet: attempt one PLC frame so the speaker does not go silent.
        if (isPlc) {
            return;
        }
        decodeLen = opus_multistream_decode(opusDecoder, NULL, 0,
                                            (short*)audioBuffer, audioConfig.samplesPerFrame, 0);
        if (decodeLen < 0) {
            Log(LOG_W, @"Opus PLC after decode failure also failed: %d", decodeLen);
            return;
        }
        isPlc = YES;
    }
    if (decodeLen == 0) {
        return;
    }
    if (!MLShouldQueueDecodedAudio(isPlc, pendingMs, kMLAudioPendingCapMs)) {
        return;
    }
    
    if (SDL_QueueAudio(audioDevice,
                       audioBuffer,
                       sizeof(short) * decodeLen * audioConfig.channelCount) < 0) {
        Log(LOG_E, @"Failed to queue audio sample: %s\n", SDL_GetError());
    }
}

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode portTestFlags:LiGetPortFlagsFromStage(stage)];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];
}

void ClConnectionTerminated(int errorCode)
{
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    va_list va;
    va_start(va, format);
    vfprintf(stderr, format, va);
    va_end(va);
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

void ClSetHdrMode(bool enabled)
{
    // Ignore the callback's enabled flag. It was read in a separate LiGetCurrentHostDisplayHdrMode
    // call before this entry point; taking enabled and metadata from two locked reads allows
    // enabled=true with a later SDR snapshot (or the reverse). LiGetHdrMetadata already returns
    // hdrEnabled and copies metadata under one lock.
    (void)enabled;
    
    SS_HDR_METADATA hdrMetadata;
    memset(&hdrMetadata, 0, sizeof(hdrMetadata));
    bool hdrOn = LiGetHdrMetadata(&hdrMetadata);
    
    [renderer setHdrMode:hdrOn metadata:hdrOn ? &hdrMetadata : NULL];
    [_callbacks setHdrMode:hdrOn];
}

void ClRumbleTriggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor)
{
    [_callbacks rumbleTriggers:controllerNumber leftTrigger:leftTriggerMotor rightTrigger:rightTriggerMotor];
}

void ClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz)
{
    [_callbacks setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

void ClSetControllerLED(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b)
{
    [_callbacks setControllerLed:controllerNumber r:r g:g b:b];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    if (videoStatsLock == nil) {
        videoStatsLock = [[NSLock alloc] init];
    }
    
    NSString *rawAddress = [Utils addressPortStringToAddress:config.host];
    strncpy(_hostString,
            [rawAddress cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString) - 1);
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString) - 1);
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString) - 1);
    }
    if (config.rtspSessionUrl != nil) {
        strncpy(_rtspSessionUrl,
                [config.rtspSessionUrl cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_rtspSessionUrl) - 1);
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }
    if (config.rtspSessionUrl != nil) {
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
    _serverInfo.serverCodecModeSupport = config.serverCodecModeSupport;

    renderer = myRenderer;
    _callbacks = callbacks;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.supportedVideoFormats = config.supportedVideoFormats;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    _streamConfig.audioQuality = config.audioQuality;
    _streamConfig.colorSpace = COLORSPACE_REC_709;
    _streamConfig.colorRange = COLOR_RANGE_FULL;
    
    Log(LOG_I, @"Stream audioConfiguration=%d audioQuality=%d bitrate=%d",
        config.audioConfiguration, config.audioQuality, config.bitRate);
    
    // Advertise client refresh so Vibepollo/Sunshine can pace to the panel
    int displayHz = 60;
    if (@available(iOS 10.3, *)) {
        displayHz = (int)[UIScreen mainScreen].maximumFramesPerSecond;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) {
                    continue;
                }
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                if (windowScene.activationState == UISceneActivationStateForegroundActive ||
                    windowScene.activationState == UISceneActivationStateForegroundInactive) {
                    displayHz = (int)windowScene.screen.maximumFramesPerSecond;
                    break;
                }
            }
        }
    }
    int refreshHz = displayHz;
    if (config.frameRate > 0 && config.frameRate < refreshHz) {
        refreshHz = config.frameRate;
    }
    _streamConfig.clientRefreshRateX100 = refreshHz * 100;
    
    // Since we require iOS 17 or above, we're guaranteed to be running
    // on a 64-bit device with ARMv8 crypto instructions, so we don't
    // need to check for that here.
    BOOL isVPN = [Utils isActiveNetworkVPN];
    BOOL isPrivateLAN = [Utils isPrivateAddress:rawAddress];
    BOOL isWiFi = [Utils isActiveNetworkWiFi];
    NetworkPathMonitor *pathMonitor = [NetworkPathMonitor sharedMonitor];
    BOOL pathConstrained = pathMonitor.hasPath && (pathMonitor.isConstrained || pathMonitor.isExpensive);

    // Opt-in LAN cleartext only: private LAN and never over VPN. Not automatic.
    int encryptionFlags = MLStreamEncryptionFlags(config.disableEncryptionOnLan, isPrivateLAN, isVPN);
    _streamConfig.encryptionFlags = encryptionFlags;
    Log(LOG_I, @"Stream encryption flags=0x%x (disableOnLan=%d privateLAN=%d vpn=%d)",
        encryptionFlags,
        config.disableEncryptionOnLan ? 1 : 0,
        isPrivateLAN ? 1 : 0,
        isVPN ? 1 : 0);
    if (encryptionFlags == ENCFLG_NONE) {
        Log(LOG_W, @"Stream encryption disabled on private LAN (user setting)");
    }
    
    int streamingRemotely = STREAM_CFG_AUTO;
    int packetSize = 1024;
    [Utils streamRemoteMode:&streamingRemotely
                 packetSize:&packetSize
                      isVPN:isVPN
               isPrivateLAN:isPrivateLAN
                     isWiFi:isWiFi
      aggressiveWifiPackets:config.aggressiveWifiPackets
            pathConstrained:pathConstrained];
    Log(LOG_I, @"Stream packetSize=%d remoteMode=%d (wifi=%d pathConstrained=%d aggressive=%d)",
        packetSize, streamingRemotely, isWiFi ? 1 : 0, pathConstrained ? 1 : 0,
        config.aggressiveWifiPackets ? 1 : 0);
    _streamConfig.streamingRemotely = streamingRemotely;
    _streamConfig.packetSize = packetSize;

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1 |
                                CAPABILITY_SLICES_PER_FRAME(4);

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.setHdrMode = ClSetHdrMode;
    _clCallbacks.rumbleTriggers = ClRumbleTriggers;
    _clCallbacks.setMotionEventState = ClSetMotionEventState;
    _clCallbacks.setControllerLED = ClSetControllerLED;

    return self;
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
