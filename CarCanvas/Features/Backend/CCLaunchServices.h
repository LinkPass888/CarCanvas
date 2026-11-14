//
//  CCLaunchServices.h
//  CarCanvas
//
//  Third way to find a container: ask LaunchServices for the application proxy
//  and read its dataContainerURL. This needs no query and no inode scan, and it
//  is the route WQFiles falls back to when ContainerManager refuses.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Data container path for `bundleID` via LSApplicationWorkspace, or nil.
NSString * _Nullable CCLSContainerPathForBundleID(NSString *bundleID);

/// Every app container LaunchServices knows about, as path -> bundle id.
/// Empty when the API is unavailable.
NSDictionary<NSString *, NSString *> * _Nonnull CCLSAllContainers(void);

/// Whether LSApplicationWorkspace is usable in this process.
BOOL CCLSIsAvailable(void);

NS_ASSUME_NONNULL_END
