//
//  CCAppGroup.m
//  CarCanvas
//

#import "CCAppGroup.h"
#import <dlfcn.h>
#import <sys/stat.h>
#import <errno.h>

// SecTask is a private iOS API: Security.framework exports the symbols but the
// SDK ships no public header. Resolve them at runtime so the build depends on
// neither a private header nor a link-time symbol, which is the approach
// Regitela uses.
typedef struct __SecTask *SecTaskRef;
typedef SecTaskRef (*CCTaskCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*CCTaskCopyValueFn)(SecTaskRef, CFStringRef, CFErrorRef *);

static NSString *CCResolvedGroup;

static BOOL CCCopyEntitledGroups(NSMutableArray<NSString *> *groups)
{
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security",
                            RTLD_NOW | RTLD_LOCAL);
    if (!security) return NO;

    CCTaskCreateFromSelfFn taskCreate =
        (CCTaskCreateFromSelfFn)dlsym(security, "SecTaskCreateFromSelf");
    CCTaskCopyValueFn copyValue =
        (CCTaskCopyValueFn)dlsym(security, "SecTaskCopyValueForEntitlement");
    if (!taskCreate || !copyValue) {
        dlclose(security);
        return NO;
    }

    SecTaskRef task = taskCreate(kCFAllocatorDefault);
    if (task) {
        CFTypeRef value = copyValue(task, CFSTR("com.apple.security.application-groups"), NULL);
        if (value) {
            if (CFGetTypeID(value) == CFArrayGetTypeID()) {
                for (id group in (__bridge NSArray *)value) {
                    if ([group isKindOfClass:[NSString class]]) [groups addObject:group];
                }
            }
            CFRelease(value);
        }
        CFRelease(task);
    }
    dlclose(security);
    return YES;
}

NSArray<NSString *> *CCAppGroupEntitledIdentifiers(void)
{
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    CCCopyEntitledGroups(groups);
    return groups;
}

NSString *CCAppGroupIdentifier(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *entitled = CCAppGroupEntitledIdentifiers();
        NSFileManager *files = [NSFileManager defaultManager];
        for (NSString *candidate in entitled) {
            // Entitled is not the same as reachable: pick the one we can open.
            if ([files containerURLForSecurityApplicationGroupIdentifier:candidate]) {
                CCResolvedGroup = candidate;
                break;
            }
        }
        NSLog(@"[CarCanvas] App Group: %@ (entitled: %@)",
              CCResolvedGroup ?: @"NONE",
              [entitled componentsJoinedByString:@", "]);
    });
    return CCResolvedGroup;
}

BOOL CCAppGroupResetCachesDirectory(NSString *group, NSError **error)
{
    if (group.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"CCAppGroup" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"No App Group available."}];
        return NO;
    }

    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"CCAppGroup" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"App Group container is not reachable."}];
        return NO;
    }

    NSString *library = [root.path stringByAppendingPathComponent:@"Library"];
    NSString *caches = [library stringByAppendingPathComponent:@"Caches"];

    struct stat st;
    if (lstat(caches.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) {
            return [files createDirectoryAtPath:caches
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:error];
        }
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }

    if (S_ISDIR(st.st_mode)) return YES; // already a plain directory

    // A leftover symlink from an interrupted worse_query run (or a stray file)
    // is moved aside rather than deleted, so nothing can be lost.
    NSString *asideName = [NSString stringWithFormat:@".carcanvas-caches-%@",
                           [[NSUUID UUID].UUIDString substringToIndex:8]];
    NSString *asidePath = [library stringByAppendingPathComponent:asideName];

    if (rename(caches.fileSystemRepresentation, asidePath.fileSystemRepresentation) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    NSLog(@"[CarCanvas] moved stale App Group Caches aside to %@", asideName);

    return [files createDirectoryAtPath:caches
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:error];
}
