//
//  CCContainerScanner.m
//  CarCanvas
//

#import "CCContainerScanner.h"
#import <dlfcn.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <time.h>

static const NSUInteger CCMetadataLimit = 256 * 1024;

typedef ssize_t (*CCFsGetPathFn)(char *, size_t, fsid_t *, uint64_t);

static CCFsGetPathFn CCCopyFsGetPath(void)
{
    static CCFsGetPathFn cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cached = (CCFsGetPathFn)dlsym(RTLD_DEFAULT, "fsgetpath"); });
    return cached;
}

/// Xattrs may require a container token on some builds. A nil result is not
/// proof that the target is absent; the scoped Swift probe retries after grant.
static NSString *CCIdentifierFromXattr(NSString *path, NSMutableArray<NSString *> *issues)
{
    for (NSString *key in @[@"com.apple.containermanager.identifier",
                            @"com.apple.containermanager.identity"]) {
        ssize_t size = getxattr(path.fileSystemRepresentation, key.UTF8String,
                                NULL, 0, 0, XATTR_NOFOLLOW);
        int sizeError = size < 0 ? errno : 0;
        if (size <= 0 || size > 65536) {
            [issues addObject:[NSString stringWithFormat:@"%@ size=%ld errno=%d", key, (long)size, sizeError]];
            continue;
        }

        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
        ssize_t count = getxattr(path.fileSystemRepresentation, key.UTF8String,
                                 data.mutableBytes, data.length, 0, XATTR_NOFOLLOW);
        int readError = count < 0 ? errno : 0;
        if (count <= 0) {
            [issues addObject:[NSString stringWithFormat:@"%@ read=%ld errno=%d", key, (long)count, readError]];
            continue;
        }
        data.length = (NSUInteger)count;

        NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (value.length == 0) {
            [issues addObject:[key stringByAppendingString:@" invalid UTF-8"]];
            continue;
        }
        NSMutableCharacterSet *ignored = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
        [ignored addCharactersInRange:NSMakeRange(0, 1)];
        NSString *newline = [NSString stringWithFormat:@"%C", (unichar)10];
        for (NSString *line in [value componentsSeparatedByString:newline]) {
            NSString *text = [line stringByTrimmingCharactersInSet:ignored];
            if ([text hasPrefix:@"identifier:"]) {
                NSString *identifier = [[text substringFromIndex:11] stringByTrimmingCharactersInSet:ignored];
                if (identifier.length) return identifier;
            }
        }
        NSString *flat = [value stringByTrimmingCharactersInSet:ignored];
        if (flat.length && ![flat containsString:@":"] && ![flat containsString:newline]) return flat;
        [issues addObject:[key stringByAppendingString:@" unrecognized identifier format"]];
    }
    return nil;
}

/// Read only the fixed identity plist, bounded and without following a link.
/// A sandbox extension cannot override a root-owned file's Unix permissions.
static NSString *CCIdentifierFromMetadata(NSString *path, NSMutableArray<NSString *> *issues)
{
    NSString *plistPath = [path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    int fd = open(plistPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        int code = errno;
        struct stat denied;
        if (lstat(plistPath.fileSystemRepresentation, &denied) == 0) {
            [issues addObject:[NSString stringWithFormat:@"metadata open errno=%d uid=%u mode=%o", code,
                               (unsigned int)denied.st_uid, (unsigned int)(denied.st_mode & 0777)]];
        } else {
            [issues addObject:[NSString stringWithFormat:@"metadata open errno=%d", code]];
        }
        return nil;
    }
    struct stat info;
    if (fstat(fd, &info) != 0) {
        int code = errno;
        close(fd);
        [issues addObject:[NSString stringWithFormat:@"metadata fstat errno=%d", code]];
        return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > (off_t)CCMetadataLimit) {
        close(fd);
        [issues addObject:@"metadata is not a bounded regular file"];
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        int code = count < 0 ? errno : 0;
        if (count < 0 && code == EINTR) continue;
        if (count <= 0) {
            close(fd);
            [issues addObject:[NSString stringWithFormat:@"metadata read=%ld errno=%d", (long)count, code]];
            return nil;
        }
        offset += (NSUInteger)count;
    }
    close(fd);
    NSError *parseError = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&parseError];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        [issues addObject:[NSString stringWithFormat:@"metadata parse failed: %@", parseError.localizedDescription ?: @"not a dictionary"]];
        return nil;
    }
    id identifier = [(NSDictionary *)plist objectForKey:@"MCMMetadataIdentifier"];
    if ([identifier isKindOfClass:[NSString class]] && [identifier length]) return identifier;
    [issues addObject:@"metadata identifier missing or invalid"];
    return nil;
}

NSString *CCContainerIdentifierWithDiagnostic(NSString *path, NSString **diagnostic)
{
    if (diagnostic) *diagnostic = nil;
    if (path.length == 0) return nil;
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    NSString *identifier = CCIdentifierFromXattr(path, issues);
    if (!identifier.length) identifier = CCIdentifierFromMetadata(path, issues);
    if (!identifier.length && diagnostic) *diagnostic = [issues componentsJoinedByString:@"; "];
    return identifier;
}

NSString *CCContainerIdentifier(NSString *path)
{
    return CCContainerIdentifierWithDiagnostic(path, NULL);
}

static NSTimeInterval CCElapsed(struct timespec start, struct timespec now)
{
    return (NSTimeInterval)(now.tv_sec - start.tv_sec) + (NSTimeInterval)(now.tv_nsec - start.tv_nsec) / 1000000000.0;
}

NSInteger CCScanApplicationContainers(NSTimeInterval budget, BOOL (^visitor)(NSString *path), NSString **diagnostic)
{
    CCFsGetPathFn fsgetpath = CCCopyFsGetPath();
    if (!fsgetpath) {
        if (diagnostic) *diagnostic = @"scan setup failed: fsgetpath symbol unavailable";
        return -1;
    }
    NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) {
        int code = errno;
        if (diagnostic) *diagnostic = [NSString stringWithFormat:@"scan probe open errno=%d", code];
        return -1;
    }
    struct stat info;
    struct statfs volume;
    BOOL valid = fstat(fd, &info) == 0 && fstatfs(fd, &volume) == 0;
    int setupError = valid ? 0 : errno;
    close(fd);
    unlink(probe.fileSystemRepresentation);
    if (!valid || info.st_ino > UINT64_MAX - 100000) {
        if (diagnostic) *diagnostic = [NSString stringWithFormat:@"scan volume setup failed errno=%d", setupError];
        return -1;
    }
    const uint64_t upper = (uint64_t)info.st_ino + 100000;
    // These are discovery sources, not grant roots. Swift grants only a
    // validated Application UUID child and never widens the final whitelist.
    static const char *roots[] = {
        "/var/mobile/Containers/Data/Application/",
        "/var/mobile/Containers/Data/InternalDaemon/",
        "/var/mobile/Containers/Data/PluginKitPlugin/",
        "/var/containers/Data/System/"
    };
    const size_t rootCount = sizeof(roots) / sizeof(roots[0]);
    NSUInteger rootCounts[4] = {0};
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    char buffer[PATH_MAX];
    NSInteger inspected = 0;
    uint64_t lastInode = 0, pathsReturned = 0;
    NSString *reason = @"upper bound";

    for (uint64_t inode = 1; inode <= upper; inode++) {
        lastInode = inode;
        if (inode == 1 || (inode & 255) == 0) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (CCElapsed(start, now) >= budget) { reason = @"budget"; break; }
        }
        if (fsgetpath(buffer, sizeof(buffer), &volume.f_fsid, inode) <= 0) continue;
        pathsReturned++;
        buffer[sizeof(buffer) - 1] = 0;
        const char *candidate = buffer;
        if (strncmp(candidate, "/private/var/", 13) == 0) candidate += 8;
        size_t matchedRoot = rootCount;
        for (size_t i = 0; i < rootCount; i++) {
            size_t rootLength = strlen(roots[i]);
            if (strncmp(candidate, roots[i], rootLength) != 0) continue;
            const char *tail = candidate + rootLength;
            if (strlen(tail) == 0 || strchr(tail, '/')) break;
            matchedRoot = i;
            break;
        }
        if (matchedRoot == rootCount) continue;
        rootCounts[matchedRoot]++;
        inspected++;
        BOOL stop = NO;
        @autoreleasepool {
            NSString *path = [NSString stringWithUTF8String:candidate];
            if (path) stop = visitor(path);
        }
        if (stop) { reason = @"visitor"; break; }
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (diagnostic) {
        *diagnostic = [NSString stringWithFormat:@"scan stopped: reason=%@ rawCandidates=%ld roots=%lu/%lu/%lu/%lu fsgetpath=%llu lastInode=%llu upperInode=%llu elapsed=%.3fs",
                       reason, (long)inspected, (unsigned long)rootCounts[0], (unsigned long)rootCounts[1],
                       (unsigned long)rootCounts[2], (unsigned long)rootCounts[3], (unsigned long long)pathsReturned,
                       (unsigned long long)lastInode, (unsigned long long)upper, CCElapsed(start, now)];
    }
    return inspected;
}
