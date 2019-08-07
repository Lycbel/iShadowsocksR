//
//  lychelp.m
//  PacketProcessor
//
//  Created by andy on 06/08/2019.
//  Copyright © 2019 ssrLive. All rights reserved.
//

#import <Foundation/Foundation.h>
#include "lychelp.h"

void lycLog(void *data) {
    NSLog(@"print:%s", data);
}

void logLL(void *form, void *data) {
    NSString *string_content = [[NSString alloc] initWithCString:(const char*)form encoding:NSASCIIStringEncoding];
    NSLog(string_content, data);
}
