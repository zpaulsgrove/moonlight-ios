//
//  RelativeTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "RelativeTouchHandler.h"

#include <Limelight.h>

static const int REFERENCE_WIDTH = 1280;
static const int REFERENCE_HEIGHT = 720;
static const int64_t kMouseClickHoldNs = 16 * NSEC_PER_MSEC;

@implementation RelativeTouchHandler {
    CGPoint touchLocation, originalLocation;
    BOOL touchMoved;
    BOOL isDragging;
    NSTimer* dragTimer;
    NSUInteger peakTouchCount;
    NSUInteger clickReleaseGeneration;
    // When a PRESS has a deferred RELEASE, cancel must release immediately or the
    // button sticks after generation invalidation.
    BOOL hasPendingClickRelease;
    int pendingClickReleaseButton;
    
#if TARGET_OS_TV
    UIGestureRecognizer* remotePressRecognizer;
    UIGestureRecognizer* remoteLongPressRecognizer;
#endif
    
    UIView* view;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;
    
#if TARGET_OS_TV
    remotePressRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonPressed:)];
    remotePressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    remoteLongPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonLongPressed:)];
    remoteLongPressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    [self->view addGestureRecognizer:remotePressRecognizer];
    [self->view addGestureRecognizer:remoteLongPressRecognizer];
#endif
    
    return self;
}

- (BOOL)isConfirmedMove:(CGPoint)currentPoint from:(CGPoint)originalPoint {
    // Movements of greater than 5 pixels are considered confirmed
    return hypotf(originalPoint.x - currentPoint.x, originalPoint.y - currentPoint.y) >= 5;
}

- (void)cancelPendingClickRelease {
    clickReleaseGeneration++;
    if (hasPendingClickRelease) {
        int button = pendingClickReleaseButton;
        hasPendingClickRelease = NO;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    }
}

- (void)scheduleMouseRelease:(int)button generation:(NSUInteger)generation {
    hasPendingClickRelease = YES;
    pendingClickReleaseButton = button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kMouseClickHoldNs),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (generation != self->clickReleaseGeneration) {
            return;
        }
        self->hasPendingClickRelease = NO;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    });
}

- (void)onDragStart:(NSTimer*)timer {
    if (!touchMoved && !isDragging){
        [self cancelPendingClickRelease];
        isDragging = true;
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    touchMoved = false;
    peakTouchCount = [[event allTouches] count];
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        originalLocation = touchLocation = [touch locationInView:view];
        if (!isDragging) {
            dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.650
                                                     target:self
                                                   selector:@selector(onDragStart:)
                                                   userInfo:nil
                                                    repeats:NO];
        }
    }
    else if ([[event allTouches] count] == 2) {
        CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
        CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
        
        originalLocation = touchLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        CGPoint currentLocation = [touch locationInView:view];
        
        if (touchLocation.x != currentLocation.x ||
            touchLocation.y != currentLocation.y)
        {
            int deltaX = (currentLocation.x - touchLocation.x) * (REFERENCE_WIDTH / view.bounds.size.width);
            int deltaY = (currentLocation.y - touchLocation.y) * (REFERENCE_HEIGHT / view.bounds.size.height);
            
            if (deltaX != 0 || deltaY != 0) {
                LiSendMouseMoveEvent(deltaX, deltaY);
                touchLocation = currentLocation;
                
                // If we've moved far enough to confirm this wasn't just human/machine error,
                // mark it as such.
                if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                    touchMoved = true;
                }
            }
        }
    } else if ([[event allTouches] count] == 2) {
        CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
        CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
        
        CGPoint avgLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
        if (touchLocation.y != avgLocation.y) {
            LiSendHighResScrollEvent((avgLocation.y - touchLocation.y) * 10);
        }

        // If we've moved far enough to confirm this wasn't just human/machine error,
        // mark it as such.
        if ([self isConfirmedMove:firstLocation from:originalLocation]) {
            touchMoved = true;
        }
        
        touchLocation = avgLocation;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;
    if (isDragging) {
        [self cancelPendingClickRelease];
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    } else if (!touchMoved) {
        if (peakTouchCount == 2) {
            [self cancelPendingClickRelease];
            NSUInteger generation = ++clickReleaseGeneration;
            Log(LOG_D, @"Sending right mouse button press");
            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
            [self scheduleMouseRelease:BUTTON_RIGHT generation:generation];
        } else if (peakTouchCount == 1) {
            if (!isDragging) {
                [self cancelPendingClickRelease];
                NSUInteger generation = ++clickReleaseGeneration;
                Log(LOG_D, @"Sending left mouse button press");
                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
                [self scheduleMouseRelease:BUTTON_LEFT generation:generation];
            } else {
                isDragging = false;
            }
        }
    }
    
    // We we're moving from 2+ touches to 1. Synchronize the current position
    // of the active finger so we don't jump unexpectedly on the next touchesMoved
    // callback when finger 1 switches on us.
    if ([[event allTouches] count] - [touches count] == 1) {
        NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
        [activeSet unionSet:[event allTouches]];
        [activeSet minusSet:touches];
        touchLocation = [[activeSet anyObject] locationInView:view];
        
        // Mark this touch as moved so we don't send a left mouse click if the user
        // right clicks without moving their other finger.
        touchMoved = true;
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;
    // Releases any deferred click before invalidating its generation.
    [self cancelPendingClickRelease];
    if (isDragging) {
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    peakTouchCount = 0;
}

#if TARGET_OS_TV
- (void)remoteButtonPressed:(id)sender {
    [self cancelPendingClickRelease];
    NSUInteger generation = ++clickReleaseGeneration;
    Log(LOG_D, @"Sending left mouse button press");
    
    // Mark this as touchMoved to avoid a duplicate press on touch up
    self->touchMoved = true;
    
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    [self scheduleMouseRelease:BUTTON_LEFT generation:generation];
}
- (void)remoteButtonLongPressed:(id)sender {
    Log(LOG_D, @"Holding left mouse button");
    
    [self cancelPendingClickRelease];
    isDragging = true;
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
}
#endif

@end
