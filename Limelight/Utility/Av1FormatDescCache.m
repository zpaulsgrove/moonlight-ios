//
//  Av1FormatDescCache.m
//  Moonlight
//

#import "Av1FormatDescCache.h"

@implementation Av1FormatDescCache {
    NSLock *_lock;
    NSData *_av1cKey;
    CMVideoFormatDescriptionRef _formatDesc;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (nullable CMVideoFormatDescriptionRef)copyFormatDescriptionForAv1C:(nullable NSData *)av1c {
    [_lock lock];
    CMVideoFormatDescriptionRef result = NULL;
    if (av1c != nil && av1c.length > 0 && _formatDesc != NULL && _av1cKey != nil &&
        [_av1cKey isEqualToData:av1c]) {
        result = (CMVideoFormatDescriptionRef)CFRetain(_formatDesc);
    }
    [_lock unlock];
    return result;
}

- (void)storeFormatDescription:(CMVideoFormatDescriptionRef)desc forAv1C:(NSData *)av1c {
    if (desc == NULL || av1c == nil || av1c.length == 0) {
        return;
    }
    [_lock lock];
    if (_formatDesc == desc && [_av1cKey isEqualToData:av1c]) {
        [_lock unlock];
        return;
    }
    _av1cKey = nil;
    if (_formatDesc != NULL) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    _av1cKey = [av1c copy];
    _formatDesc = (CMVideoFormatDescriptionRef)CFRetain(desc);
    [_lock unlock];
}

- (void)invalidate {
    [_lock lock];
    _av1cKey = nil;
    if (_formatDesc != NULL) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    [_lock unlock];
}

@end
