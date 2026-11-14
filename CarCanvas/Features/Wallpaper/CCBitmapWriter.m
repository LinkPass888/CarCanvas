//
//  CCBitmapWriter.m
//  CarCanvas
//

#import "CCBitmapWriter.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// The private selector lives on UIImage and takes (NSString *path, int flags).
// It is resolved dynamically so the build needs no private header, and the
// call is guarded so an absent implementation degrades instead of crashing.
typedef BOOL (*CCWriteToCPBitmapFn)(id, SEL, NSString *, int);

static BOOL CCCanWriteCPBitmap(void)
{
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        available = [UIImage instanceMethodForSelector:NSSelectorFromString(@"writeToCPBitmapFile:flags:")] != NULL;
    });
    return available;
}

BOOL CCBitmapWriterIsAvailable(void)
{
    return CCCanWriteCPBitmap();
}

BOOL CCWriteCPBitmap(CGImageRef image, NSURL *path, NSError **error)
{
    if (!image) {
        if (error) *error = [NSError errorWithDomain:@"CCBitmapWriter" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"No image to write."}];
        return NO;
    }
    if (path.path.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"CCBitmapWriter" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"No destination path."}];
        return NO;
    }
    if (!CCCanWriteCPBitmap()) {
        if (error) *error = [NSError errorWithDomain:@"CCBitmapWriter" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                                            @"This iOS build does not expose the system CPBitmap writer."}];
        return NO;
    }

    SEL selector = NSSelectorFromString(@"writeToCPBitmapFile:flags:");
    CCWriteToCPBitmapFn write = (CCWriteToCPBitmapFn)[UIImage instanceMethodForSelector:selector];
    if (!write) {
        if (error) *error = [NSError errorWithDomain:@"CCBitmapWriter" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                                            @"The system CPBitmap writer could not be resolved."}];
        return NO;
    }

    @try {
        UIImage *uiImage = [UIImage imageWithCGImage:image];
        if (!uiImage) {
            if (error) *error = [NSError errorWithDomain:@"CCBitmapWriter" code:4
                                                userInfo:@{NSLocalizedDescriptionKey: @"Could not wrap the image."}];
            return NO;
        }
        // flags: 1 matches what the system files use in practice.
        BOOL ok = write(uiImage, selector, path.path, 1);
        if (!ok && error) {
            *error = [NSError errorWithDomain:@"CCBitmapWriter" code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"The system refused to write the file."}];
        }
        return ok;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"CCBitmapWriter" code:6
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"CPBitmap write failed."}];
        }
        return NO;
    }
}
