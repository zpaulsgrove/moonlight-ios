//
//  AudioPlaybackHelpers.m
//  Moonlight
//

#import "AudioPlaybackHelpers.h"

NSTimeInterval MLPreferredAudioIOBufferDuration(int sampleRate, int samplesPerFrame) {
    if (sampleRate <= 0 || samplesPerFrame <= 0) {
        return 0.005;
    }
    NSTimeInterval seconds = (NSTimeInterval)samplesPerFrame / (NSTimeInterval)sampleRate;
    if (seconds < 0.0025) {
        return 0.0025;
    }
    if (seconds > 0.010) {
        return 0.010;
    }
    return seconds;
}

int MLAudioPacketDurationMs(int sampleRate, int samplesPerFrame) {
    if (sampleRate <= 0 || samplesPerFrame <= 0) {
        return 5;
    }
    int ms = (samplesPerFrame * 1000) / sampleRate;
    return ms > 0 ? ms : 5;
}

int MLSdlQueuedAudioDurationMs(unsigned int queuedBytes, int frameBytes, int packetDurationMs) {
    if (frameBytes <= 0 || packetDurationMs <= 0) {
        return 0;
    }
    return (int)(queuedBytes / (unsigned int)frameBytes) * packetDurationMs;
}

int MLCombinedAudioPendingMs(int lbqDurationMs, int sdlDurationMs) {
    int lbq = lbqDurationMs > 0 ? lbqDurationMs : 0;
    int sdl = sdlDurationMs > 0 ? sdlDurationMs : 0;
    return lbq + sdl;
}

BOOL MLShouldQueueDecodedAudio(BOOL isPlc, int combinedPendingMs, int capMs) {
    if (isPlc) {
        return YES;
    }
    int cap = capMs > 0 ? capMs : kMLAudioPendingCapMs;
    return combinedPendingMs <= cap;
}
