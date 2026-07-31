//
//  Utils.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Utils.h"

#import <Network/Network.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netdb.h>
#include <Limelight.h>

@implementation Utils
NSString *const deviceName = @"roth";

+ (NSData*) randomBytes:(NSInteger)length {
    char* bytes = malloc(length);
    arc4random_buf(bytes, length);
    NSData* randomData = [NSData dataWithBytes:bytes length:length];
    free(bytes);
    return randomData;
}

+ (NSData*) hexToBytes:(NSString*) hex {
    unsigned long len = [hex length];
    NSMutableData* data = [NSMutableData dataWithCapacity:len / 2];
    char byteChars[3] = {'\0','\0','\0'};
    unsigned long wholeByte;
    
    const char *chars = [hex UTF8String];
    int i = 0;
    while (i < len) {
        byteChars[0] = chars[i++];
        byteChars[1] = chars[i++];
        wholeByte = strtoul(byteChars, NULL, 16);
        [data appendBytes:&wholeByte length:1];
    }
    
    return data;
}

+ (NSString*) bytesToHex:(NSData*)data {
    const unsigned char* bytes = [data bytes];
    NSMutableString *hex = [[NSMutableString alloc] init];
    for (int i = 0; i < [data length]; i++) {
        [hex appendFormat:@"%02X" , bytes[i]];
    }
    return hex;
}

+ (BOOL)isActiveNetworkVPN {
    NSDictionary *dict = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    NSArray *keys = [dict[@"__SCOPED__"] allKeys];
    for (NSString *key in keys) {
        if ([key containsString:@"tap"] ||
            [key containsString:@"tun"] ||
            [key containsString:@"ppp"] ||
            [key containsString:@"ipsec"]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)isActiveNetworkWiFi {
    __block BOOL usesWiFi = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        usesWiFi = nw_path_uses_interface_type(path, nw_interface_type_wifi);
        dispatch_semaphore_signal(sem);
    });
    nw_path_monitor_start(monitor);
    // Bound wait so stream setup cannot hang if the path callback is delayed
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)));
    nw_path_monitor_cancel(monitor);
    return usesWiFi;
}

+ (void)streamRemoteMode:(int*)streamingRemotely
              packetSize:(int*)packetSize
                   isVPN:(BOOL)isVPN
            isPrivateLAN:(BOOL)isPrivateLAN
                  isWiFi:(BOOL)isWiFi {
    if (streamingRemotely == NULL || packetSize == NULL) {
        return;
    }
    if (isVPN) {
        *streamingRemotely = STREAM_CFG_REMOTE;
        *packetSize = 1024;
    }
    else if (isPrivateLAN) {
        *streamingRemotely = STREAM_CFG_LOCAL;
        *packetSize = isWiFi ? 1024 : 1392;
    }
    else {
        *streamingRemotely = STREAM_CFG_AUTO;
        *packetSize = 1024;
    }
}

+ (BOOL)isPrivateAddress:(NSString*)address {
    if (address.length == 0) {
        return NO;
    }
    
    // mDNS / .local hostnames are same-LAN
    if ([address.lowercaseString hasSuffix:@".local"]) {
        return YES;
    }
    
    struct in_addr addr4;
    if (inet_pton(AF_INET, [address UTF8String], &addr4) == 1) {
        uint32_t hostOrder = ntohl(addr4.s_addr);
        // 10.0.0.0/8
        if ((hostOrder & 0xFF000000) == 0x0A000000) {
            return YES;
        }
        // 172.16.0.0/12
        if ((hostOrder & 0xFFF00000) == 0xAC100000) {
            return YES;
        }
        // 192.168.0.0/16
        if ((hostOrder & 0xFFFF0000) == 0xC0A80000) {
            return YES;
        }
        // 127.0.0.0/8
        if ((hostOrder & 0xFF000000) == 0x7F000000) {
            return YES;
        }
        return NO;
    }
    
    struct in6_addr addr6;
    if (inet_pton(AF_INET6, [address UTF8String], &addr6) == 1) {
        // Unique local fc00::/7 or link-local fe80::/10
        if ((addr6.s6_addr[0] & 0xFE) == 0xFC ||
            (addr6.s6_addr[0] == 0xFE && (addr6.s6_addr[1] & 0xC0) == 0x80)) {
            return YES;
        }
        // Loopback ::1
        if (IN6_IS_ADDR_LOOPBACK(&addr6)) {
            return YES;
        }
    }
    
    return NO;
}

+ (BOOL)isSunshineLineageAppVersion:(NSString*)appVersion {
    // Sunshine / Apollo / Vibepollo advertise a negative build in the last version quad
    // (serialized with ".-"), which avoids GFE's FPS>60 launch hacks.
    return appVersion != nil && [appVersion containsString:@".-"];
}

#if !TARGET_OS_TV
+ (void) launchUrl:(NSString*)urlString {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlString] options:@{} completionHandler:nil];
}
#endif

+ (void) addHelpOptionToDialog:(UIAlertController*)dialog {
#if !TARGET_OS_TV
    // tvOS doesn't have a browser
    [dialog addAction:[UIAlertAction actionWithTitle:@"Help" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        [Utils launchUrl:@"https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting"];
    }]];
#endif
}

+ (BOOL) parseAddressPortString:(NSString*)addressPort address:(NSRange*)address port:(NSRange*)port {
    if (![addressPort containsString:@":"]) {
        // If there's no port or IPv6 separator, the whole thing is an address
        *address = NSMakeRange(0, [addressPort length]);
        *port = NSMakeRange(NSNotFound, 0);
        return TRUE;
    }
    
    NSInteger locationOfOpeningBracket = [addressPort rangeOfString:@"["].location;
    NSInteger locationOfClosingBracket = [addressPort rangeOfString:@"]"].location;
    if (locationOfOpeningBracket != NSNotFound || locationOfClosingBracket != NSNotFound) {
        // If we have brackets, it's an IPv6 address
        if (locationOfOpeningBracket == NSNotFound || locationOfClosingBracket == NSNotFound ||
            locationOfClosingBracket < locationOfOpeningBracket) {
            // Invalid address format
            return FALSE;
        }
        
        // Cut at the brackets
        *address = NSMakeRange(locationOfOpeningBracket + 1, locationOfClosingBracket - locationOfOpeningBracket - 1);
    }
    else {
        // It's an IPv4 address, so just cut at the port separator
        *address = NSMakeRange(0, [addressPort rangeOfString:@":"].location);
    }
    
    NSUInteger remainingStringLocation = address->location + address->length;
    NSRange remainingStringRange = NSMakeRange(remainingStringLocation, [addressPort length] - remainingStringLocation);
    NSInteger locationOfPortSeparator = [addressPort rangeOfString:@":" options:0 range:remainingStringRange].location;
    if (locationOfPortSeparator != NSNotFound) {
        *port = NSMakeRange(locationOfPortSeparator + 1, [addressPort length] - locationOfPortSeparator - 1);
    }
    else {
        *port = NSMakeRange(NSNotFound, 0);
    }
    
    return TRUE;
}

+ (NSString*) addressPortStringToAddress:(NSString*)addressPort {
    NSRange addressRange, portRange;
    if (![self parseAddressPortString:addressPort address:&addressRange port:&portRange]) {
        return nil;
    }
    
    return [addressPort substringWithRange:addressRange];
}

+ (unsigned short) addressPortStringToPort:(NSString*)addressPort {
    NSRange addressRange, portRange;
    if (![self parseAddressPortString:addressPort address:&addressRange port:&portRange] || portRange.location == NSNotFound) {
        return 47989;
    }
    
    return [[addressPort substringWithRange:portRange] integerValue];
}

+ (NSString*) addressAndPortToAddressPortString:(NSString*)address port:(unsigned short)port {
    if ([address containsString:@":"]) {
        // IPv6 addresses require escaping
        return [NSString stringWithFormat:@"[%@]:%u", address, port];
    }
    else {
        return [NSString stringWithFormat:@"%@:%u", address, port];
    }
}

@end

@implementation NSString (NSStringWithTrim)

- (NSString *)trim {
    return [self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end
