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
    BOOL nativeTouchChecked;
    BOOL useNativeTouch;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;
    self->nativeTouchChecked = NO;
    self->useNativeTouch = NO;
    return self;
}

- (BOOL)shouldUseNativeTouch {
    if (!nativeTouchChecked) {
        // Host feature flags are populated after LiStartConnection; probe on first use
        useNativeTouch = (LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS) != 0;
        nativeTouchChecked = YES;
    }
    return useNativeTouch;
}

- (BOOL)sendNativeTouch:(UITouch*)touch withType:(uint8_t)type {
    CGPoint location = [view adjustCoordinatesForVideoArea:[touch locationInView:view]];
    CGSize videoSize = [view getVideoAreaSize];
    if (videoSize.width <= 0 || videoSize.height <= 0) {
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
    return err != LI_ERR_UNSUPPORTED;
}

- (void)onLongPressStart:(NSTimer*)timer {
    // Raise the left click and start a right click (mouse-emulation path only)
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self shouldUseNativeTouch]) {
        for (UITouch* touch in touches) {
            if (![self sendNativeTouch:touch withType:LI_TOUCH_EVENT_DOWN]) {
                useNativeTouch = NO;
                break;
            }
        }
        if (useNativeTouch) {
            return;
        }
        // Host rejected native touch; fall through to mouse emulation for this gesture
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
