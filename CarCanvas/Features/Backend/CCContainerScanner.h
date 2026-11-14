//
//  CCContainerScanner.h
//  CarCanvas
//
//  Bounded discovery of candidate paths. A path is not a container identity:
//  the Swift access layer may need a scoped grant before reading its label.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Visits direct child container paths, stopping when `visitor` returns YES
/// or the monotonic budget elapses. Returns raw candidate count, or -1 on
/// setup failure. `diagnostic` records stop reason, counts and setup errno.
NSInteger CCScanApplicationContainers(NSTimeInterval budget,
                                      BOOL (^visitor)(NSString *path),
                                      NSString * _Nullable * _Nullable diagnostic);

/// Reads xattr first, then readable metadata. Does not acquire an extension.
NSString * _Nullable CCContainerIdentifier(NSString *path);
NSString * _Nullable CCContainerIdentifierWithDiagnostic(NSString *path,
                                                         NSString * _Nullable * _Nullable diagnostic);

NS_ASSUME_NONNULL_END
