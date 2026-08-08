//
//  AnnexBHelpers.m
//  Moonlight
//

#import "AnnexBHelpers.h"

#include <string.h>

int MLFindAnnexBNals(const uint8_t *data, int length,
                     int *outOffsets, int *outPrefixLengths,
                     int maxNals) {
    if (data == NULL || outOffsets == NULL || maxNals <= 0 || length < 3) {
        return 0;
    }
    
    int count = 0;
    for (int i = 0; i < length - 3; ) {
        if (data[i + 2] > 1) {
            i += 3;
        }
        else if (data[i + 2] == 1) {
            if (data[i] == 0 && data[i + 1] == 0) {
                int start = i;
                int prefixLen = 3;
                // 00 00 00 01: include the leading 00
                if (i > 0 && data[i - 1] == 0) {
                    start = i - 1;
                    prefixLen = 4;
                }
                if (count < maxNals) {
                    outOffsets[count] = start;
                    if (outPrefixLengths != NULL) {
                        outPrefixLengths[count] = prefixLen;
                    }
                }
                count++;
            }
            i += 3;
        }
        else {
            i++;
        }
    }
    return count;
}

int MLFindAnnexBStartOffsets(const uint8_t *data, int length,
                             int *outOffsets, int maxOffsets) {
    return MLFindAnnexBNals(data, length, outOffsets, NULL, maxOffsets);
}

int MLRewriteAnnexBToLengthPrefixed(uint8_t *data, int length,
                                    int capacity, int *outLength) {
    if (data == NULL || outLength == NULL || length < 3 || capacity < length) {
        return -1;
    }
    
    int offsets[256];
    int prefixes[256];
    int count = MLFindAnnexBNals(data, length, offsets, prefixes, 256);
    if (count <= 0 || count > 256) {
        return -1;
    }
    
    // In-place compact/rewrite assumes the first start code is at byte 0.
    if (offsets[0] != 0) {
        return -1;
    }
    
    BOOL allFour = YES;
    int threeCount = 0;
    for (int i = 0; i < count; i++) {
        if (prefixes[i] != 4) {
            allFour = NO;
            if (prefixes[i] == 3) {
                threeCount++;
            }
            else {
                return -1;
            }
        }
    }
    
    if (allFour) {
        for (int n = 0; n < count; n++) {
            int start = offsets[n];
            int end = (n + 1 < count) ? offsets[n + 1] : length;
            int payloadLen = end - start - 4;
            if (payloadLen < 0) {
                return -1;
            }
            data[start + 0] = (uint8_t)(payloadLen >> 24);
            data[start + 1] = (uint8_t)(payloadLen >> 16);
            data[start + 2] = (uint8_t)(payloadLen >> 8);
            data[start + 3] = (uint8_t)payloadLen;
        }
        *outLength = length;
        return 0;
    }
    
    int finalSize = length + threeCount;
    if (capacity < finalSize) {
        return -1;
    }
    
    int outPos[256];
    int payloadLen[256];
    int pos = 0;
    for (int n = 0; n < count; n++) {
        int start = offsets[n];
        int end = (n + 1 < count) ? offsets[n + 1] : length;
        int plen = end - start - prefixes[n];
        if (plen < 0) {
            return -1;
        }
        outPos[n] = pos;
        payloadLen[n] = plen;
        pos += 4 + plen;
    }
    
    // Move payloads from last to first so we never overwrite unread source bytes
    for (int n = count - 1; n >= 0; n--) {
        int srcPayload = offsets[n] + prefixes[n];
        memmove(data + outPos[n] + 4, data + srcPayload, (size_t)payloadLen[n]);
        int plen = payloadLen[n];
        data[outPos[n] + 0] = (uint8_t)(plen >> 24);
        data[outPos[n] + 1] = (uint8_t)(plen >> 16);
        data[outPos[n] + 2] = (uint8_t)(plen >> 8);
        data[outPos[n] + 3] = (uint8_t)plen;
    }
    
    *outLength = finalSize;
    return 0;
}
