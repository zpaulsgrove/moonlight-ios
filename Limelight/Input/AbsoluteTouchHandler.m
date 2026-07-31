//
//  AbsoluteTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "AbsoluteTouchHandler.h"

#include <Limelight.h>

// How long the fingers must be stationary to start a right click
#define LONG_PRESS_ACTIVATION_DELAY 0.650f

// How far the finger can move before it cancels a right click
#define LONG_PRESS_ACTIVATION_DELTA 0.01f

// How long the double tap deadzone stays in effect between touch up and touch down
#define DOUBLE_TAP_DEAD_ZONE_DELAY 0.250f

// How far the finger can move before it can override the double tap deadzone
#define DOUBLE_TAP_DEAD_ZONE_DELTA 0.025f

@interface StreamView (AbsoluteTouchHelpers)
- (CGSize)getVideoAreaSize;
- (CGPoint)adjustCoordinatesForVideoArea:(CGPoint)point;
@end

@implementation AbsoluteTouchHandler {
    StreamView* view;
    
    NSTimer* longPressTimer;
    UITouch* lastTouchDown;
    CGPoint lastTouchDownLocation;
    UITouch* lastTouchUp;
    CGPoint lastTouchUpLocation;
    BOOL nativeTouchResolved;
    BOOL useNativeTouch;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;
    self->nativeTouchResolved = NO;
    self->useNativeTouch = NO;
    return self;
}

- (BOOL)shouldUseNativeTouch {
    if (nativeTouchResolved) {
        return useNativeTouch;
    }
    
    // Feature flags are populated during RTSP. Keep probing until they are non-zero
    // so we do not permanently latch mouse emulation before LiStartConnection finishes.
    uint32_t flags = LiGetHostFeatureFlags();
    if (flags == 0) {
        return NO;
    }
    
    useNativeTouch = (flags & LI_FF_PEN_TOUCH_EVENTS) != 0;
    nativeTouchResolved = YES;
    return useNativeTouch;
}

- (BOOL)sendNativeTouch:(UITouch*)touch withType:(uint8_t)type {
    CGPoint location = [view adjustCoordinatesForVideoArea:[touch locationInView:view]];
    CGSize videoSize = [view getVideoAreaSize];
    if (videoSize.width <= 0 || videoSize.height <= 0) {
        // Layout not ready yet; do not disable native touch for the session.
        return NO;
    }
    
    float x = location.x / videoSize.width;
    float y = location.y / videoSize.height;
    float pressure = 0.0f;
    if (touch.maximumPossibleForce > 0) {
        pressure = touch.force / touch.maximumPossibleForce;
    }
    
    // Opaque pointer ID that stays stable for the life of the UITouch
    uint32_t pointerId = (uint32_t)(uintptr_t)touch;
    
    int err = LiSendTouchEvent(type, pointerId, x, y, pressure, 0.0f, 0.0f, LI_ROT_UNKNOWN);
    return err == 0;
}

- (void)fallbackToMouseEmulationAfterNativeFailure {
    // Cancel any pointers already sent as native downs before switching paths.
    LiSendTouchEvent(LI_TOUCH_EVENT_CANCEL_ALL, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN);
    useNativeTouch = NO;
    nativeTouchResolved = YES;
}

- (void)onLongPressStart:(NSTimer*)timer {
    // Raise the left click and start a right click (mouse-emulation path only)
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self shouldUseNativeTouch]) {
        BOOL allSent = YES;
        for (UITouch* touch in touches) {
            if (![self sendNativeTouch:touch withType:LI_TOUCH_EVENT_DOWN]) {
                allSent = NO;
                break;
            }
        }
        if (allSent) {
            return;
        }
        
        CGSize videoSize = [view getVideoAreaSize];
        if (videoSize.width > 0 && videoSize.height > 0) {
            // Host/queue rejected native touch after layout was ready; cancel and latch mouse.
            [self fallbackToMouseEmulationAfterNativeFailure];
        }
        // Else layout not ready: leave native mode unresolved and use mouse for this gesture only.
    }
    
    // Ignore touch down events with more than one finger
    if ([[event allTouches] count] > 1) {
        return;
    }
    
    UITouch* touch = [touches anyObject];
    CGPoint touchLocation = [touch locationInView:view];
    
    // Don't reposition for finger down events within the deadzone. This makes double-clicking easier.
    if (touch.timestamp - lastTouchUp.timestamp > DOUBLE_TAP_DEAD_ZONE_DELAY ||
        sqrt(pow((touchLocation.x / view.bounds.size.width) - (lastTouchUpLocation.x / view.bounds.size.width), 2) +
             pow((touchLocation.y / view.bounds.size.height) - (lastTouchUpLocation.y / view.bounds.size.height), 2)) > DOUBLE_TAP_DEAD_ZONE_DELTA) {
        [view updateCursorLocation:touchLocation isMouse:NO];
    }
    
    // Press the left button down
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    
    // Start the long press timer
    longPressTimer = [NSTimer scheduledTimerWithTimeInterval:LONG_PRESS_ACTIVATION_DELAY
                                                      target:self
                                                    selector:@selector(onLongPressStart:)
                                                    userInfo:nil
                                                     repeats:NO];
    
    lastTouchDown = touch;
    lastTouchDownLocation = touchLocation;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self shouldUseNativeTouch]) {
        for (UITouch* touch in touches) {
            [self sendNativeTouch:touch withType:LI_TOUCH_EVENT_MOVE];
        }
        return;
    }
    
    // Ignore touch move events with more than one finger
    if ([[event allTouches] count] > 1) {
        return;
    }
    
    UITouch* touch = [touches anyObject];
    CGPoint touchLocation = [touch locationInView:view];
    
    if (sqrt(pow((touchLocation.x / view.bounds.size.width) - (lastTouchDownLocation.x / view.bounds.size.width), 2) +
             pow((touchLocation.y / view.bounds.size.height) - (lastTouchDownLocation.y / view.bounds.size.height), 2)) > LONG_PRESS_ACTIVATION_DELTA) {
        // Moved too far since touch down. Cancel the long press timer.
        [longPressTimer invalidate];
        longPressTimer = nil;
    }
    
    [view updateCursorLocation:[[touches anyObject] locationInView:view] isMouse:NO];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self shouldUseNativeTouch]) {
        for (UITouch* touch in touches) {
            [self sendNativeTouch:touch withType:LI_TOUCH_EVENT_UP];
        }
        return;
    }
    
    // Only fire this logic if all touches have ended
    if ([[event allTouches] count] == [touches count]) {
        // Cancel the long press timer
        [longPressTimer invalidate];
        longPressTimer = nil;

        // Left button up on finger up
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);

        // Raise right button too in case we triggered a long press gesture
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        
        // Remember this last touch for touch-down deadzoning
        lastTouchUp = [touches anyObject];
        lastTouchUpLocation = [lastTouchUp locationInView:view];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self shouldUseNativeTouch]) {
        for (UITouch* touch in touches) {
            [self sendNativeTouch:touch withType:LI_TOUCH_EVENT_CANCEL];
        }
        return;
    }
    
    // Treat this as a normal touchesEnded event
    [self touchesEnded:touches withEvent:event];
}

@end
