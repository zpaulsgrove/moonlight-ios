//
//  AnnexBHelpers.m
//  Moonlight
//

#import "AnnexBHelpers.h"

int MLFindAnnexBStartOffsets(const uint8_t *data, int length,
                             int *outOffsets, int maxOffsets) {
    if (data == NULL || outOffsets == NULL || maxOffsets <= 0 || length < 3) {
        return 0;
    }
    
    int count = 0;
    for (int i = 0; i < length - 3; ) {
        if (data[i + 2] > 1) {
            i += 3;
        }
        else if (data[i + 2] == 1) {
            if (data[i] == 0 && data[i + 1] == 0) {
                if (count < maxOffsets) {
                    outOffsets[count] = i;
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
