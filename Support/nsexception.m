//
//  nsexception.m
//  Support
//
//  Vendored from SwiftExtensions's NSExceptionSupport target.
//

#import <Foundation/Foundation.h>
#import "nsexception.h"

@implementation _nsexception

+ (NSError *)catchException:(NSError * (NS_NOESCAPE ^)(void))tryBlock exception: (out NSException **)exception {
    @try {
        *exception = nil;
        return tryBlock();
    }
    @catch (NSException *localException) {
        *exception = localException;
        return nil;
    }
}

@end
