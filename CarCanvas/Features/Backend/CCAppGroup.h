//
//  CCAppGroup.h
//  CarCanvas
//
//  Runtime App Group discovery, following the approach used by WQFiles and
//  Regitela: read the entitlement that the *signer* actually embedded, instead
//  of hard-coding a group name. Whichever group the signing tool provides is
//  the one worse_query uses.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the first App Group from this app's own code signature that can
/// actually be opened, or nil when the build was signed without one.
/// Safe to call repeatedly; the result is cached.
NSString * _Nullable CCAppGroupIdentifier(void);

/// All App Group identifiers present in the signature, for diagnostics.
NSArray<NSString *> *CCAppGroupEntitledIdentifiers(void);

/// worse_query swaps App Group `Library/Caches` for a symlink and normally
/// removes it again. An interrupted run can leave that symlink behind, which
/// makes every later query fail. This restores a plain directory without
/// deleting anything: whatever is in the way is moved aside.
BOOL CCAppGroupResetCachesDirectory(NSString * _Nullable group, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
