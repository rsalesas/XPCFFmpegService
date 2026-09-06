//
//  nsexception.h
//  Support
//
//  Vendored from SwiftExtensions's NSExceptionSupport target
//  (https://github.com/rsalesas/SwiftExtensions) - Swift cannot catch
//  Objective-C NSExceptions natively, so this tiny shim bridges @try/@catch
//  into something Swift can call.
//

#import <Foundation/Foundation.h>

@interface _nsexception : NSObject

+ (NSError *)catchException:(NSError * (NS_NOESCAPE ^)(void))tryBlock exception: (out NSException **)exception;

@end
