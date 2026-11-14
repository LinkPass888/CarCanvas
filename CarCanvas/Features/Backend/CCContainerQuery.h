//
//  CCContainerQuery.h
//  CarCanvas
//
//  Looks a container up BY BUNDLE IDENTIFIER through ContainerManager, which is
//  what the original CarCanvas did (container_query_set_identifiers ->
//  container_object_get_path -> container_object_sandbox_extension_activate).
//
//  This is instantaneous. The bounded inode scan is only a fallback for builds
//  where the query is refused; on iOS 26 that scan can take the better part of
//  an hour, so it must never be the primary route.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves the data container path for `bundleID`, or nil.
/// Does not need an App Group; this is a read-only lookup.
NSString * _Nullable CCContainerPathForBundleID(NSString *bundleID);

/// Resolves `bundleID` and activates the sandbox extension ContainerManager
/// issues for it. On success `outPath` receives the container path and
/// `outToken` the extension token, which the caller consumes and releases.
BOOL CCContainerLookup(NSString *bundleID,
                       NSString * _Nullable * _Nullable outPath,
                       NSString * _Nullable * _Nullable outToken);

/// Whether the ContainerManager query symbols are available at all.
BOOL CCContainerQueryIsAvailable(void);

/// Consumes a token produced by CCContainerLookup and returns a handle usable
/// with worse_query_release(). Returns a negative value on failure.
int64_t CCConsumeContainerToken(NSString *token);

NS_ASSUME_NONNULL_END
