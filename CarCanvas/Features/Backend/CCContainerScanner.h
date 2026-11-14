//
//  CCContainerScanner.h
//  CarCanvas
//
//  Bounded container discovery. Reading a container's identifier from its
//  xattr needs no sandbox extension, so the scan can find the CarPlayWallpaper
//  container before consuming a single extension. Approach follows WQFiles and
//  Placard's ContainerEnumeration.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Visits first-level application container paths, newest inodes first is not
/// guaranteed; stops early when `visitor` returns YES or `budget` elapses.
/// Returns the number of candidates inspected, or -1 if setup failed.
NSInteger CCScanApplicationContainers(NSTimeInterval budget,
                                      BOOL (^visitor)(NSString *path));

/// The container's bundle identifier, read from the `com.apple.containermanager.*`
/// xattrs. Returns nil when neither xattr is present or readable.
NSString * _Nullable CCContainerIdentifier(NSString *path);

NS_ASSUME_NONNULL_END
