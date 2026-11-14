//
//  CCContainerScanner.m
//  CarCanvas
//

#import "CCContainerScanner.h"
#import <dlfcn.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <errno.h>
#import <string.h>
#import <time.h>

typedef ssize_t (*CCFsGetPathFn)(char *, size_t, fsid_t *, uint64_t);

static CCFsGetPathFn CCCopyFsGetPath(void)
{
    static CCFsGetPathFn cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cached = (CCFsGetPathFn)dlsym(RTLD_DEFAULT, "fsgetpath"); });
    return cached;
}

/// Reads the container's identifier from its extended attribute.
///
/// This is the ONLY route that works from inside the sandbox: the metadata
/// plist is not readable for other apps' containers, so preferring it made
/// every one of the ~1500 scanned containers fail to identify. WQFiles reads
/// the xattr for exactly this reason (wq_container_identifier_lookup).
static NSString *CCIdentifierFromXattr(NSString *path)
{
    for (NSString *key in @[@"com.apple.containermanager.identifier",
                            @"com.apple.containermanager.identity"]) {
        ssize_t size = getxattr(path.fileSystemRepresentation, key.UTF8String,
                                NULL, 0, 0, XATTR_NOFOLLOW);
        if (size <= 0 || size > 65536) continue;

        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
        ssize_t count = getxattr(path.fileSystemRepresentation, key.UTF8String,
                                 data.mutableBytes, data.length, 0, XATTR_NOFOLLOW);
        if (count <= 0) continue;
        data.length = (NSUInteger)count;

        NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (value.length == 0) continue;

        NSCharacterSet *ignored = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        // The identity xattr is a small block that can list several fields;
        // the identifier one is usually just the bundle id. Split on a real
        // newline built from its code point so no escaping layer can break it.
        NSString *newline = [NSString stringWithFormat:@"%C", (unichar)10];
        for (NSString *line in [value componentsSeparatedByString:newline]) {
            NSString *text = [line stringByTrimmingCharactersInSet:ignored];
            if ([text hasPrefix:@"identifier:"]) {
                NSString *identifier = [[text substringFromIndex:11]
                                        stringByTrimmingCharactersInSet:ignored];
                if (identifier.length) return identifier;
            }
        }
        NSString *flat = [value stringByTrimmingCharactersInSet:ignored];
        BOOL hasColon = [flat containsString:@":"];
        BOOL multiline = [flat containsString:newline];
        if (flat.length && !hasColon && !multiline) {
            return flat;
        }
    }
    return nil;
}

/// Metadata plist, kept only as a fallback for a container we already hold an
/// extension for. Outside that case it will fail, which is expected.
static NSString *CCIdentifierFromMetadata(NSString *path)
{
    NSString *plistPath = [path stringByAppendingPathComponent:
                           @".com.apple.mobile_container_manager.metadata.plist"];
    NSData *data = [NSData dataWithContentsOfFile:plistPath];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                        options:0
                                                         format:NULL
                                                          error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    NSString *identifier = [(NSDictionary *)plist objectForKey:@"MCMMetadataIdentifier"];
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

NSString *CCContainerIdentifier(NSString *path)
{
    if (path.length == 0) return nil;
    // xattr first: it is the one thing readable without an extension.
    NSString *fromXattr = CCIdentifierFromXattr(path);
    if (fromXattr.length) return fromXattr;
    return CCIdentifierFromMetadata(path);
}

NSInteger CCScanApplicationContainers(NSTimeInterval budget, BOOL (^visitor)(NSString *path))
{
    CCFsGetPathFn fsgetpath = CCCopyFsGetPath();
    if (!fsgetpath) return -1;

    NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;

    struct stat info;
    struct statfs volume;
    BOOL valid = fstat(fd, &info) == 0 && fstatfs(fd, &volume) == 0;
    close(fd);
    unlink(probe.fileSystemRepresentation);
    if (!valid || info.st_ino > UINT64_MAX - 100000) return -1;

    const uint64_t upper = (uint64_t)info.st_ino + 100000;

    // iOS 27 moved system/daemon containers under /var/containers, so both
    // roots have to be walked. This list mirrors what worse_query reports as
    // reachable.
    static const char *roots[] = {
        "/var/mobile/Containers/Data/Application/",
        "/var/mobile/Containers/Data/InternalDaemon/",
        "/var/mobile/Containers/Data/PluginKitPlugin/",
        "/var/containers/Data/System/"
    };
    const size_t rootCount = sizeof(roots) / sizeof(roots[0]);

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    char buffer[PATH_MAX];
    NSInteger inspected = 0;

    for (uint64_t inode = 1; inode <= upper; inode++) {
        if ((inode & 2047) == 0) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - start.tv_sec >= (time_t)budget) break;
        }
        if (fsgetpath(buffer, sizeof(buffer), &volume.f_fsid, inode) <= 0) continue;

        const char *candidate = buffer;
        if (strncmp(candidate, "/private/var/", 13) == 0) candidate += 8;

        BOOL matched = NO;
        for (size_t i = 0; i < rootCount; i++) {
            size_t rootLength = strlen(roots[i]);
            if (strncmp(candidate, roots[i], rootLength) != 0) continue;
            const char *tail = candidate + rootLength;
            // Direct children only; names are UUIDs or identifiers.
            if (strlen(tail) == 0 || strchr(tail, '/')) break;
            matched = YES;
            break;
        }
        if (!matched) continue;

        inspected++;
        @autoreleasepool {
            NSString *path = [NSString stringWithUTF8String:candidate];
            if (path && visitor(path)) return inspected;
        }
    }
    return inspected;
}
