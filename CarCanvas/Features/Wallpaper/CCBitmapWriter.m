// System UIImage CPBitmap categories, dynamically resolved with ABI checks.
#import "CCBitmapWriter.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

// RuntimeBrowser's UIKitCore/UIImage.h declares:
// + (id)imageWithContentsOfCPBitmapFile:(id)path flags:(int)flags;
// - (bool)writeToCPBitmapFile:(id)path flags:(int)flags;
// https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/UIImage.h
// Do not try an unverified CPBitmapCreateImagesFromData C-function signature.
typedef id (*CCReadCPBitmapFn)(id, SEL, NSString *, int);
typedef BOOL (*CCWriteCPBitmapFn)(id, SEL, NSString *, int);

static BOOL CCMethodHasSignature(Method method, BOOL reader)
{
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    char *result = method_copyReturnType(method);
    char *path = method_copyArgumentType(method, 2);
    char *flags = method_copyArgumentType(method, 3);
    BOOL valid = result && path && flags && path[0] == '@' && strcmp(flags, "i") == 0;
    valid = valid && (reader ? result[0] == '@' : (strcmp(result, "B") == 0 || strcmp(result, "c") == 0));
    free(result); free(path); free(flags);
    return valid;
}

static void CCBitmapError(NSError **error, NSInteger code, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:@"CCBitmapWriter" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL CCBitmapWriterIsAvailable(void)
{
    return CCMethodHasSignature(class_getInstanceMethod(UIImage.class, NSSelectorFromString(@"writeToCPBitmapFile:flags:")), NO);
}

BOOL CCWriteCPBitmap(CGImageRef image, NSURL *path, NSError **error)
{
    if (error) *error = nil;
    if (!image || !path.isFileURL || path.path.length == 0) {
        CCBitmapError(error, 1, @"No image or local destination to write.");
        return NO;
    }
    SEL selector = NSSelectorFromString(@"writeToCPBitmapFile:flags:");
    Method method = class_getInstanceMethod(UIImage.class, selector);
    if (!CCMethodHasSignature(method, NO)) {
        CCBitmapError(error, 3, @"The system CPBitmap writer is absent or has an unsupported signature.");
        return NO;
    }
    @try {
        UIImage *uiImage = [UIImage imageWithCGImage:image];
        CCWriteCPBitmapFn write = (CCWriteCPBitmapFn)method_getImplementation(method);
        BOOL ok = uiImage && write(uiImage, selector, path.path, 1);
        if (!ok) CCBitmapError(error, 5, @"The system refused to write the CPBitmap.");
        return ok;
    } @catch (NSException *exception) {
        CCBitmapError(error, 6, exception.reason ?: @"CPBitmap write failed.");
        return NO;
    }
}

CGImageRef CCCopyCPBitmapImage(NSURL *path, NSError **error)
{
    if (error) *error = nil;
    if (!path.isFileURL || path.path.length == 0) {
        CCBitmapError(error, 7, @"No local CPBitmap to read.");
        return NULL;
    }
    SEL selector = NSSelectorFromString(@"imageWithContentsOfCPBitmapFile:flags:");
    Method method = class_getClassMethod(UIImage.class, selector);
    if (!CCMethodHasSignature(method, YES)) {
        CCBitmapError(error, 8, @"The system CPBitmap reader is absent or has an unsupported signature.");
        return NULL;
    }
    @try {
        CCReadCPBitmapFn read = (CCReadCPBitmapFn)method_getImplementation(method);
        id decoded = read(UIImage.class, selector, path.path, 0);
        if (![decoded isKindOfClass:UIImage.class] || ![(UIImage *)decoded CGImage]) {
            CCBitmapError(error, 9, @"The system could not decode the CPBitmap.");
            return NULL;
        }
        return CGImageRetain([(UIImage *)decoded CGImage]);
    } @catch (NSException *exception) {
        CCBitmapError(error, 10, exception.reason ?: @"CPBitmap read failed.");
        return NULL;
    }
}
