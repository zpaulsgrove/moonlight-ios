//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "StreamView.h"
#import "AnnexBHelpers.h"
#import "HdrMetadataHelpers.h"

void DrNoteClientQueueAgeMs(uint64_t ageMs);

#include <stdatomic.h>
#include <string.h>

#include <os/lock.h>
#include <os/log.h>
#include <os/signpost.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

static os_log_t VideoRendererSignpostLog(void)
{
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.moonlight-stream.Moonlight", "renderer");
    });
    return log;
}

@implementation VideoDecoderRenderer {
    StreamView* _view;
    id<ConnectionCallbacks> _callbacks;
    float _streamAspectRatio;
    
    // The layer and its renderer are created and replaced on the main thread only. The
    // submission thread reads them through _layerLock and carries the generation it saw, so
    // it can never enqueue into a renderer that main has already thrown away.
    os_unfair_lock _layerLock;
    AVSampleBufferDisplayLayer* displayLayer;
    AVSampleBufferVideoRenderer* videoRenderer;
    uint64_t _layerGeneration;
    
    int videoFormat;
    int frameRate;
    
    // Decode state below belongs exclusively to whichever thread drives submission.
    NSMutableArray *parameterSetBuffers;
    NSData *masteringDisplayColorVolume;
    NSData *contentLightLevelInfo;
    CMVideoFormatDescriptionRef formatDesc;
    uint64_t _shownGeneration;
    
    CADisplayLink* _displayLink;
    BOOL framePacing;
    
    // Arrival-path soft-drop skips P-frames without decoding them. Until an IDR is enqueued,
    // later P-frames would paint as corruption, so we refuse them and request one IDR for the
    // whole streak rather than one per skipped frame.
    BOOL _arrivalDecodeChainBroken;
    BOOL _arrivalIdrRequestedForSoftDrop;
    
    NSThread* _renderThread;
    dispatch_semaphore_t _renderThreadExited;
    atomic_bool _stopping;
    BOOL _stopped;
    
    // HDR snapshot handed over from the control callback thread. Only the newest pending
    // snapshot survives, so a burst of host toggles cannot produce a burst of IDR requests.
    os_unfair_lock _hdrLock;
    BOOL _pendingHdrValid;
    BOOL _pendingHdrEnabled;
    BOOL _pendingHdrHasMetadata;
    SS_HDR_METADATA _pendingHdrMetadata;
}

// Main-thread-only layer surgery. Decode state is deliberately not touched here.
- (void)createDisplayLayer
{
    AVSampleBufferDisplayLayer* newLayer = [[AVSampleBufferDisplayLayer alloc] init];
    newLayer.backgroundColor = [UIColor blackColor].CGColor;
    newLayer.opaque = YES;
    newLayer.preventsDisplaySleepDuringVideoPlayback = YES;
    
    // Ensure the AVSampleBufferDisplayLayer is sized to preserve the aspect ratio
    // of the video stream. We used to use AVLayerVideoGravityResizeAspect, but that
    // respects the PAR encoded in the SPS which causes our computed video-relative
    // touch location to be wrong in StreamView if the aspect ratio of the host
    // desktop doesn't match the aspect ratio of the stream.
    CGSize videoSize;
    if (_view.bounds.size.width > _view.bounds.size.height * _streamAspectRatio) {
        videoSize = CGSizeMake(_view.bounds.size.height * _streamAspectRatio, _view.bounds.size.height);
    } else {
        videoSize = CGSizeMake(_view.bounds.size.width, _view.bounds.size.width / _streamAspectRatio);
    }
    newLayer.position = CGPointMake(CGRectGetMidX(_view.bounds), CGRectGetMidY(_view.bounds));
    newLayer.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
    newLayer.videoGravity = AVLayerVideoGravityResize;

    // Hide the layer until we get an IDR frame. This ensures we
    // can see the loading progress label as the stream is starting.
    newLayer.hidden = YES;
    
    os_unfair_lock_lock(&_layerLock);
    AVSampleBufferDisplayLayer* oldLayer = displayLayer;
    displayLayer = newLayer;
    videoRenderer = newLayer.sampleBufferRenderer;
    _layerGeneration++;
    os_unfair_lock_unlock(&_layerLock);
    
    if (oldLayer != nil) {
        // Switch out the old display layer with the new one
        [_view.layer replaceSublayer:oldLayer with:newLayer];
    }
    else {
        [_view.layer addSublayer:newLayer];
    }
}

// Submission-thread-only counterpart to createDisplayLayer.
- (void)resetDecodeState
{
    if (formatDesc != NULL) {
        CFRelease(formatDesc);
        formatDesc = NULL;
    }
    [parameterSetBuffers removeAllObjects];
}

- (AVSampleBufferVideoRenderer*)currentVideoRenderer:(uint64_t*)outGeneration
{
    os_unfair_lock_lock(&_layerLock);
    AVSampleBufferVideoRenderer* current = videoRenderer;
    if (outGeneration != NULL) {
        *outGeneration = _layerGeneration;
    }
    os_unfair_lock_unlock(&_layerLock);
    return current;
}

- (AVSampleBufferDisplayLayer*)currentDisplayLayer
{
    os_unfair_lock_lock(&_layerLock);
    AVSampleBufferDisplayLayer* current = displayLayer;
    os_unfair_lock_unlock(&_layerLock);
    return current;
}

- (uint64_t)currentLayerGeneration
{
    os_unfair_lock_lock(&_layerLock);
    uint64_t generation = _layerGeneration;
    os_unfair_lock_unlock(&_layerLock);
    return generation;
}

- (id)initWithView:(StreamView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing
{
    self = [super init];
    
    _view = view;
    _callbacks = callbacks;
    _streamAspectRatio = aspectRatio;
    framePacing = useFramePacing;
    _layerLock = OS_UNFAIR_LOCK_INIT;
    _hdrLock = OS_UNFAIR_LOCK_INIT;
    _renderThreadExited = dispatch_semaphore_create(0);
    atomic_init(&_stopping, false);
    
    parameterSetBuffers = [[NSMutableArray alloc] init];
    
    [self createDisplayLayer];
    
    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate
{
    self->videoFormat = videoFormat;
    self->frameRate = frameRate;
}

- (void)start
{
    _arrivalDecodeChainBroken = NO;
    _arrivalIdrRequestedForSoftDrop = NO;
    
    if (framePacing) {
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(self->frameRate, self->frameRate, self->frameRate);
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    else {
        // A real thread rather than a dispatch queue: the loop blocks in
        // LiWaitForNextVideoFrame and would otherwise occupy a cooperative pool thread.
        _renderThread = [[NSThread alloc] initWithTarget:self selector:@selector(renderThreadMain) object:nil];
        _renderThread.name = @"Moonlight video render";
        _renderThread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_renderThread start];
    }
}

// TODO: Refactor this
MLEnqueueResult DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

// The wait, the drop decision, the enqueue, and LiCompleteVideoFrame all have to run on one
// thread: the depacketizer asserts an idrFrameProcessed ordering that a split would break, and
// completion is what frees the decode unit. Do not move completion elsewhere.
- (void)renderThreadMain
{
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    
    while (!atomic_load(&_stopping)) {
        BOOL haveFrame = LiWaitForNextVideoFrame(&handle, &du);
        
        if (!haveFrame) {
            // The wait only fails on shutdown or on our own LiWakeWaitForVideoFrame.
            // Do not applyPendingHdrUpdate here: LiWake races with a pending HDR snapshot and
            // apply would LiRequestIdrFrame on a connection that is already stopping.
            break;
        }
        
        [self applyPendingHdrUpdate];
        [self submitFrame:handle decodeUnit:du];
    }
    
    dispatch_semaphore_signal(_renderThreadExited);
}

- (void)displayLinkCallback:(CADisplayLink *)sender
{
    os_signpost_id_t signpostId = os_signpost_id_generate(VideoRendererSignpostLog());
    
    // Tick quantization: how far past its own tick this callback actually entered
    double tickJitterMs = (CACurrentMediaTime() - sender.timestamp) * 1000.0;
    os_signpost_interval_begin(VideoRendererSignpostLog(), signpostId, "DisplayLinkCallback",
                               "tickJitterMs=%.3f", tickJitterMs);
    
    [self applyPendingHdrUpdate];
    
    // Calculate the actual display refresh rate
    double displayRefreshRate = 1 / (sender.targetTimestamp - sender.timestamp);
    
    // Only pace frames if the display refresh rate is >= 90% of our stream frame rate.
    // Battery saver, accessibility settings, or device thermals can cause the actual
    // refresh rate of the display to drop below the physical maximum.
    BOOL pace = displayRefreshRate >= frameRate * 0.9f;
    
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    while (LiPollNextVideoFrame(&handle, &du)) {
        MLEnqueueResult result = [self submitFrame:handle decodeUnit:du];
        
        // Presenting one frame per refresh is the whole point of frame pacing
        if (pace && result == MLEnqueueResultEnqueued) {
            break;
        }
    }
    
    os_signpost_interval_end(VideoRendererSignpostLog(), signpostId, "DisplayLinkCallback");
}

// Shared by both submission drivers, so there is exactly one implementation of the state machine.
- (MLEnqueueResult)submitFrame:(VIDEO_FRAME_HANDLE)handle decodeUnit:(PDECODE_UNIT)du
{
    os_signpost_id_t signpostId = os_signpost_id_generate(VideoRendererSignpostLog());
    
    // Recapture the clock here rather than at loop entry so frame age is measured truthfully
    uint64_t nowMs = LiGetMillis();
    uint64_t frameAgeMs = (nowMs > du->enqueueTimeMs) ? (nowMs - du->enqueueTimeMs) : 0;
    
    // Never skip-decode IDRs: LiCompleteVideoFrame(DR_OK) would mark idrFrameProcessed
    // without a real decode and leave later P-frames without a keyframe.
    BOOL isIdr = (du->frameType == FRAME_TYPE_IDR);
    
    // Prefer the newest frame only on the arrival-driven path. Soft-completing a skipped
    // P-frame never feeds it to the decoder, so reference chains break until an IDR. After the
    // first skip we request one IDR for the streak and refuse later P-frames until that
    // keyframe is enqueued. Frame pacing drains in order and never soft-drops.
    int pendingFrames = LiGetPendingVideoFrames();
    BOOL dropForNewest = !framePacing && !isIdr && pendingFrames >= 1;
    BOOL dropBrokenChain = !framePacing && !isIdr && _arrivalDecodeChainBroken;
    BOOL drop = dropForNewest || dropBrokenChain;
    
    DrNoteClientQueueAgeMs(frameAgeMs);
    
    os_signpost_interval_begin(VideoRendererSignpostLog(), signpostId, "SubmitFrame",
                               "frameAgeMs=%llu pending=%d", frameAgeMs, pendingFrames);
    
    MLEnqueueResult result;
    int drStatus;
    
    if (drop) {
        result = MLEnqueueResultDropped;
        if (!_arrivalIdrRequestedForSoftDrop) {
            _arrivalDecodeChainBroken = YES;
            _arrivalIdrRequestedForSoftDrop = YES;
            drStatus = DR_NEED_IDR;
        }
        else {
            drStatus = DR_OK;
        }
    }
    else {
        result = DrSubmitDecodeUnit(du);
        drStatus = (result == MLEnqueueResultNeedsIdr) ? DR_NEED_IDR : DR_OK;
        if (isIdr && result == MLEnqueueResultEnqueued) {
            _arrivalDecodeChainBroken = NO;
            _arrivalIdrRequestedForSoftDrop = NO;
        }
    }
    
    if (atomic_load(&_stopping)) {
        // DR_NEED_IDR flushes the queue and requests a keyframe on a connection that is
        // already being torn down, so in-flight frames always complete cleanly after the latch.
        drStatus = DR_OK;
    }
    LiCompleteVideoFrame(handle, drStatus);
    
    os_signpost_interval_end(VideoRendererSignpostLog(), signpostId, "SubmitFrame",
                             "result=%ld", (long)result);
    return result;
}

- (void)stop
{
    if (_stopped) {
        return;
    }
    _stopped = YES;
    
    // Latch before waking so any frame still in flight completes as DR_OK
    atomic_store(&_stopping, true);
    
    if (_displayLink != nil) {
        CADisplayLink* displayLink = _displayLink;
        _displayLink = nil;
        if ([NSThread isMainThread]) {
            [displayLink invalidate];
        }
        else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [displayLink invalidate];
            });
        }
    }
    
    if (_renderThread != nil) {
        // The streaming core destroys the depacketizer queue and its mutex shortly after stop
        // returns, so the render thread has to be gone before we hand control back.
        LiWakeWaitForVideoFrame();
        dispatch_semaphore_wait(_renderThreadExited, DISPATCH_TIME_FOREVER);
        _renderThread = nil;
    }
}

#define NAL_LENGTH_PREFIX_SIZE 4

- (NSData*)getAv1CodecConfigurationBox:(NSData*)frameData  {
    AVIOContext* ioctx = NULL;
    int err;
    
    err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t*)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
        // Fall-through to close and free buffer
    }
    
    // Close the dynbuf and get the underlying buffer back (which we must free)
    uint8_t* av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);
    
    Log(LOG_I, @"av1C block is %d bytes", av1cBufLen);
    
    // Only return data if ff_isom_write_av1c() was successful
    NSData* data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }
    else {
        data = nil;
    }
    
    av_free(av1cBuf);
    return data;
}

// Much of this logic comes from Chrome
- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData*)frameData {
    NSMutableDictionary* extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext* cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return nil;
    }
    
    AVPacket avPacket = {};
    avPacket.data = (uint8_t*)frameData.bytes;
    avPacket.size = (int)frameData.length;
    
    // Read the sequence header OBU
    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }
    
#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (__bridge NSString*)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");
    
    // We use the value for YUV without alpha, same as Chrome
    // https://developer.apple.com/library/archive/qa/qa1183/_index.html
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);
    
    CodedBitstreamAV1Context* bitstreamCtx = (CodedBitstreamAV1Context*)cbsCtx->priv_data;
    AV1RawSequenceHeader* seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame!");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }
    
    switch (seqHeader->color_config.color_primaries) {
        case 1: // CP_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;
            
        case 6: // CP_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;
            
        case 9: // CP_BT_2020
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;
            
        default:
            Log(LOG_W, @"Unsupported color_primaries value: %d", seqHeader->color_config.color_primaries);
            break;
    }
    
    switch (seqHeader->color_config.transfer_characteristics) {
        case 1: // TC_BT_709
        case 6: // TC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;
            
        case 7: // TC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;
            
        case 8: // TC_LINEAR
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_Linear);
            break;
            
        case 14: // TC_BT_2020_10_BIT
        case 15: // TC_BT_2020_12_BIT
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;
            
        case 16: // TC_SMPTE_2084
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;
            
        case 17: // TC_HLG
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;
            
        default:
            Log(LOG_W, @"Unsupported transfer_characteristics value: %d", seqHeader->color_config.transfer_characteristics);
            break;
    }
    
    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: // MC_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;
            
        case 6: // MC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;
            
        case 7: // MC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;
            
        case 9: // MC_BT_2020_NCL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;
            
        default:
            Log(LOG_W, @"Unsupported matrix_coefficients value: %d", seqHeader->color_config.matrix_coefficients);
            break;
    }
    
    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));
    
    // Progressive content
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));
    
    switch (seqHeader->color_config.chroma_sample_position) {
        case 1: // CSP_VERTICAL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_Left);
            break;
            
        case 2: // CSP_COLOCATED
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_TopLeft);
            break;
            
        default:
            Log(LOG_W, @"Unsupported chroma_sample_position value: %d", seqHeader->color_config.chroma_sample_position);
            break;
    }
    
    if (contentLightLevelInfo) {
        SET_EXTENSION(kCMFormatDescriptionExtension_ContentLightLevelInfo, contentLightLevelInfo);
    }
    
    if (masteringDisplayColorVolume) {
        SET_EXTENSION(kCMFormatDescriptionExtension_MasteringDisplayColorVolume, masteringDisplayColorVolume);
    }
    
    // Referenced the VP9 code in Chrome that performs a similar function
    // https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/mac/vt_config_util.mm;drc=977dc02c431b4979e34c7792bc3d646f649dacb4;l=155
    extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
    @{
        @"av1C" : [self getAv1CodecConfigurationBox:frameData],
    };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);
    
#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION
    
    // AV1 doesn't have a special format description function like H.264 and HEVC have, so we just use the generic one
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width, bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &formatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }
    
    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}

// Picture data is gathered once into a CMBlockBuffer-owned allocation (no intermediate assembly buffer).
- (MLEnqueueResult)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du
{
    OSStatus status;
    BOOL isIdr = (du->frameType == FRAME_TYPE_IDR);
    
    // Parameter sets are submitted individually before picture data
    if (bufferType != BUFFER_TYPE_PICDATA) {
        if (isIdr) {
            if (bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS) {
                int startLen = data[2] == 0x01 ? 3 : 4;
                [parameterSetBuffers addObject:[NSData dataWithBytes:&data[startLen] length:length - startLen]];
            }
        }
        // Data is NOT to be freed here. It's a direct usage of the caller's buffer.
        return MLEnqueueResultDropped;
    }
    
    // Pin the renderer we are submitting into for the whole call, along with the generation it
    // belongs to, so a concurrent main-thread layer replacement cannot be missed.
    uint64_t generation;
    AVSampleBufferVideoRenderer* currentRenderer = [self currentVideoRenderer:&generation];
    
    // Soft-drop before gather/rewrite when the renderer is saturated. IDRs must not return
    // DR_OK without enqueue (that falsely sets idrFrameProcessed); request a fresh keyframe.
    if (![currentRenderer isReadyForMoreMediaData]) {
        return isIdr ? MLEnqueueResultNeedsIdr : MLEnqueueResultDropped;
    }
    
    // Capacity leaves headroom so 3-byte Annex-B can compact to 4-byte length prefixes in place
    int capacity = du->fullLength + 256;
    if (capacity < 256) {
        capacity = 256;
    }
    
    CMBlockBufferRef dataBlockBuffer = NULL;
    status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, capacity, kCFAllocatorDefault, NULL, 0, capacity,
                                                kCMBlockBufferAssureMemoryNowFlag, &dataBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        return MLEnqueueResultNeedsIdr;
    }
    
    size_t dataOffsetAt = 0;
    size_t dataLengthAt = 0;
    char* dataPointer = NULL;
    status = CMBlockBufferGetDataPointer(dataBlockBuffer, 0, &dataOffsetAt, &dataLengthAt, &dataPointer);
    if (status != noErr || dataPointer == NULL) {
        Log(LOG_E, @"CMBlockBufferGetDataPointer failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return MLEnqueueResultNeedsIdr;
    }
    
    unsigned char* dest = (unsigned char*)dataPointer;
    int picLength = 0;
    if (data != NULL && length > 0) {
        if (length > capacity) {
            CFRelease(dataBlockBuffer);
            return MLEnqueueResultNeedsIdr;
        }
        memcpy(dest, data, (size_t)length);
        picLength = length;
    }
    else {
        for (PLENTRY entry = du->bufferList; entry != NULL; entry = entry->next) {
            if (entry->bufferType != BUFFER_TYPE_PICDATA) {
                continue;
            }
            if (picLength + entry->length > capacity) {
                CFRelease(dataBlockBuffer);
                return MLEnqueueResultNeedsIdr;
            }
            memcpy(dest + picLength, entry->data, (size_t)entry->length);
            picLength += entry->length;
        }
    }
    
    if (picLength <= 0) {
        CFRelease(dataBlockBuffer);
        return MLEnqueueResultNeedsIdr;
    }
    
    // Construct a new format description object each time we receive an IDR frame
    if (isIdr) {
        // Free the old format description
        if (formatDesc != NULL) {
            CFRelease(formatDesc);
            formatDesc = NULL;
        }
        
        if (videoFormat & VIDEO_FORMAT_MASK_H264) {
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }
            
            Log(LOG_I, @"Constructing new H264 format description");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &formatDesc);
            if (status != noErr) {
                Log(LOG_E, @"Failed to create H264 format description: %d", (int)status);
                formatDesc = NULL;
            }
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }
            
            Log(LOG_I, @"Constructing new HEVC format description");
            
            NSMutableDictionary* videoFormatParams = [[NSMutableDictionary alloc] init];
            
            if (contentLightLevelInfo) {
                [videoFormatParams setObject:contentLightLevelInfo forKey:(__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo];
            }
            
            if (masteringDisplayColorVolume) {
                [videoFormatParams setObject:masteringDisplayColorVolume forKey:(__bridge NSString*)kCMFormatDescriptionExtension_MasteringDisplayColorVolume];
            }
            
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         (__bridge CFDictionaryRef)videoFormatParams,
                                                                         &formatDesc);
            
            if (status != noErr) {
                Log(LOG_E, @"Failed to create HEVC format description: %d", (int)status);
                formatDesc = NULL;
            }
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
            NSData* fullFrameData = [NSData dataWithBytesNoCopy:dest length:picLength freeWhenDone:NO];
            
            Log(LOG_I, @"Constructing new AV1 format description");
            formatDesc = [self createAV1FormatDescriptionForIDRFrame:fullFrameData];
        }
        else {
            CFRelease(dataBlockBuffer);
            abort();
        }
    }
    
    if (formatDesc == NULL) {
        CFRelease(dataBlockBuffer);
        return MLEnqueueResultNeedsIdr;
    }
    
    if (currentRenderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        Log(LOG_E, @"Video renderer failed: %@", currentRenderer.error);
        [self recoverFromFailedRenderer:currentRenderer generation:generation];
        CFRelease(dataBlockBuffer);
        return MLEnqueueResultNeedsIdr;
    }
    
    int sampleLength = picLength;
    if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        os_signpost_id_t rewriteId = os_signpost_id_generate(VideoRendererSignpostLog());
        os_signpost_interval_begin(VideoRendererSignpostLog(), rewriteId, "AnnexBRewrite",
                                   "bytes=%d", picLength);
        int outLength = 0;
        int rewriteResult = MLRewriteAnnexBToLengthPrefixed(dest, picLength, capacity, &outLength);
        os_signpost_interval_end(VideoRendererSignpostLog(), rewriteId, "AnnexBRewrite");
        if (rewriteResult != 0) {
            Log(LOG_E, @"Annex-B length-prefix rewrite failed");
            CFRelease(dataBlockBuffer);
            return MLEnqueueResultNeedsIdr;
        }
        sampleLength = outLength;
    }
    
    CMBlockBufferRef frameBlockBuffer = NULL;
    status = CMBlockBufferCreateWithBufferReference(NULL, dataBlockBuffer, 0, sampleLength, 0, &frameBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithBufferReference failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return MLEnqueueResultNeedsIdr;
    }
        
    CMSampleBufferRef sampleBuffer;
    
    CMSampleTimingInfo sampleTiming = {kCMTimeInvalid, CMTimeMake(du->presentationTimeMs, 1000), kCMTimeInvalid};
    
    // CMSampleBufferCreateReady does not retain the format description until it returns, so
    // hold our own reference across the call.
    CMVideoFormatDescriptionRef sampleFormatDesc = (CMVideoFormatDescriptionRef)CFRetain(formatDesc);
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  sampleFormatDesc, 1, 1,
                                  &sampleTiming, 0, NULL,
                                  &sampleBuffer);
    CFRelease(sampleFormatDesc);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        return MLEnqueueResultNeedsIdr;
    }
    
    // The presentation timestamps are host-derived, or synthesized from local receive time when
    // the host sends none, so they are tied to no client clock and cannot act as a timeline.
    // Present on dequeue instead of trusting them.
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachmentsArray != NULL && CFArrayGetCount(attachmentsArray) > 0) {
        CFMutableDictionaryRef attachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
        CFDictionarySetValue(attachments, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    // Re-check and enqueue under the same lock so a concurrent createDisplayLayer cannot leave
    // this sample on a discarded renderer while we still report Enqueued.
    os_signpost_id_t enqueueId = os_signpost_id_generate(VideoRendererSignpostLog());
    os_signpost_interval_begin(VideoRendererSignpostLog(), enqueueId, "Enqueue",
                               "bytes=%d", sampleLength);
    
    AVSampleBufferDisplayLayer* layerToReveal = nil;
    BOOL shouldReveal = NO;
    
    os_unfair_lock_lock(&_layerLock);
    BOOL canEnqueue = (_layerGeneration == generation &&
                       videoRenderer == currentRenderer &&
                       [videoRenderer isReadyForMoreMediaData]);
    if (!canEnqueue) {
        os_unfair_lock_unlock(&_layerLock);
        os_signpost_interval_end(VideoRendererSignpostLog(), enqueueId, "Enqueue");
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        CFRelease(sampleBuffer);
        return isIdr ? MLEnqueueResultNeedsIdr : MLEnqueueResultDropped;
    }
    
    [videoRenderer enqueueSampleBuffer:sampleBuffer];
    
    // Defer _shownGeneration until reveal succeeds so a skipped reveal leaves a future IDR
    // free to try again on this or a later generation.
    if (isIdr && _shownGeneration != generation) {
        layerToReveal = displayLayer;
        shouldReveal = (layerToReveal != nil);
    }
    os_unfair_lock_unlock(&_layerLock);
    
    os_signpost_interval_end(VideoRendererSignpostLog(), enqueueId, "Enqueue");
    
    if (shouldReveal) {
        uint64_t revealGeneration = generation;
        dispatch_async(dispatch_get_main_queue(), ^{
            os_unfair_lock_lock(&self->_layerLock);
            BOOL stillCurrent = (self->_layerGeneration == revealGeneration &&
                                 self->displayLayer == layerToReveal &&
                                 self->_shownGeneration != revealGeneration);
            if (stillCurrent) {
                self->_shownGeneration = revealGeneration;
            }
            os_unfair_lock_unlock(&self->_layerLock);
            
            if (!stillCurrent) {
                return;
            }
            
            // Reveal the layer and dismiss the progress indicator in one block so they can
            // never be split across frames
            layerToReveal.hidden = NO;
            [self->_callbacks videoContentShown];
        });
    }
    
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);
    
    return MLEnqueueResultEnqueued;
}

// Called on the submission thread. flush is background-safe, so it is tried before falling back
// to main-thread layer replacement. We never set upcoming-presentation-time expectations, so
// there is nothing for the flush to invalidate; if that ever changes, re-establish them here.
- (void)recoverFromFailedRenderer:(AVSampleBufferVideoRenderer*)failedRenderer generation:(uint64_t)generation
{
    [failedRenderer flush];
    [self resetDecodeState];
    
    if (failedRenderer.status != AVQueuedSampleBufferRenderingStatusFailed) {
        return;
    }
    
    Log(LOG_E, @"Video renderer did not recover from flush; replacing the display layer");
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self currentLayerGeneration] != generation) {
            // An earlier failure already replaced this layer
            return;
        }
        [self createDisplayLayer];
    });
}

- (void)setHdrMode:(BOOL)enabled metadata:(const SS_HDR_METADATA*)metadata {
    os_unfair_lock_lock(&_hdrLock);
    _pendingHdrEnabled = enabled;
    _pendingHdrHasMetadata = (metadata != NULL);
    if (metadata != NULL) {
        _pendingHdrMetadata = *metadata;
    }
    else {
        memset(&_pendingHdrMetadata, 0, sizeof(_pendingHdrMetadata));
    }
    // Overwriting rather than queueing is the coalescing: N queued changes produce at most one IDR
    _pendingHdrValid = YES;
    os_unfair_lock_unlock(&_hdrLock);
}

// Runs on the submission thread, which owns masteringDisplayColorVolume and contentLightLevelInfo.
- (void)applyPendingHdrUpdate {
    if (atomic_load(&_stopping)) {
        return;
    }
    
    BOOL enabled;
    BOOL hasMetadata;
    SS_HDR_METADATA hdrMetadata;
    
    os_unfair_lock_lock(&_hdrLock);
    if (!_pendingHdrValid) {
        os_unfair_lock_unlock(&_hdrLock);
        return;
    }
    _pendingHdrValid = NO;
    enabled = _pendingHdrEnabled;
    hasMetadata = _pendingHdrHasMetadata;
    hdrMetadata = _pendingHdrMetadata;
    os_unfair_lock_unlock(&_hdrLock);
    
    if (enabled) {
        // Defaults make an HDR host with empty metadata usable, so from here on the snapshot
        // always describes a mastering display.
        MLApplyHdrMetadataDefaults(&hdrMetadata);
        hasMetadata = YES;
    }
    else {
        hasMetadata = NO;
    }
    
    NSData* newMdcv = hasMetadata ? MLMasteringDisplayColorVolumeData(&hdrMetadata) : nil;
    NSData* newCll = hasMetadata ? MLContentLightLevelInfoData(&hdrMetadata) : nil;
    BOOL metadataChanged = NO;
    
    if (newMdcv != nil) {
        if (masteringDisplayColorVolume == nil || ![newMdcv isEqualToData:masteringDisplayColorVolume]) {
            masteringDisplayColorVolume = newMdcv;
            metadataChanged = YES;
        }
    }
    else if (masteringDisplayColorVolume != nil) {
        masteringDisplayColorVolume = nil;
        metadataChanged = YES;
    }
    
    if (newCll != nil) {
        if (contentLightLevelInfo == nil || ![newCll isEqualToData:contentLightLevelInfo]) {
            contentLightLevelInfo = newCll;
            metadataChanged = YES;
        }
    }
    else if (contentLightLevelInfo != nil) {
        contentLightLevelInfo = nil;
        metadataChanged = YES;
    }
    
    // If the metadata changed, request an IDR frame to re-create the CMVideoFormatDescription.
    // Re-check stop so a snapshot that landed during teardown cannot still request an IDR.
    if (metadataChanged && !atomic_load(&_stopping)) {
        LiRequestIdrFrame();
    }
}

@end
