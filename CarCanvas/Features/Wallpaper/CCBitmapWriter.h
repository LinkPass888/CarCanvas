//
//  CCBitmapWriter.h
//  CarCanvas
//
//  Writes a CPBitmap using the system's own image category, which is how the
//  original CarCanvas produced local files. This does NOT need a cache file on
//  the device, so "Create Local CPBitmap" works before CarPlay has ever
//  generated one.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Writes `image` to `path` as a CPBitmap. Returns YES on success.
/// `error` is filled in when the system method is unavailable or refuses.
BOOL CCWriteCPBitmap(CGImageRef image, NSURL *path, NSError * _Nullable * _Nullable error);

/// System CPBitmap reader. The caller must hold its scoped file access until
/// it has rendered a small, independent thumbnail from this retained image.
CGImageRef _Nullable CCCopyCPBitmapImage(NSURL *path, NSError * _Nullable * _Nullable error) CF_RETURNS_RETAINED;

/// Whether the system CPBitmap writer is available on this OS build.
BOOL CCBitmapWriterIsAvailable(void);

NS_ASSUME_NONNULL_END
