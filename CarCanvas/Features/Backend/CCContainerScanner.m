//
//  CCContainerScanner.m
//  CarCanvas
//

#import "CCContainerScanner.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <errno.h>
#import <string.h>
#import <time.h>

// fsgetpath is not in the public SDK headers on every toolchain, so resolve it
// at runtime rather than depending on a private header or a link-time symbol.
typedef ssize_t (*CCFsGetPathFn)(char *, size_t, fsid_t *, uint64_t);

static CCFsGetPathFn CCCopyFsGetPath(void)
{
    static CCFsGetPathFn cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = (CCFsGetPathFn)dlsym(RTLD_DEFAULT, "fsgetpath");
    });
    return cached;
}

NSString *CCContainerIdentifier(NSString *path)
{
    if (path.length == 0) return nil;

    for (NSString *key in @[@"com.apple.containermanager.identity",
                            @"com.apple.containermanager.identifier"]) {
        ssize_t size = getxattr(path.fileSystemRepresentation, key.UTF8String, NULL, 0, 0, XATTR_NOFOLLOW);
        if (size <= 0 || size > 65536) continue;

        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
        ssize_t count = getxattr(path.fileSystemRepresentation, key.UTF8String,
                                 data.mutableBytes, data.length, 0, XATTR_NOFOLLOW);
        if (count <= 0) continue;
        data.length = (NSUInteger)count;

        NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (value.length == 0) continue;

        NSMutableCharacterSet *ignored = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
        [ignored addCharactersInString:[NSString stringWithFormat:@"%C", (unichar)0]];

        for (NSString *line in [value componentsSeparatedByString:@"\n"]) {
            NSString *text = [line stringByTrimmingCharactersInSet:ignored];
            if ([text hasPrefix:@"identifier:"]) {
                NSString *identifier = [text substringFromIndex:11];
                identifier = [identifier stringByTrimmingCharactersInSet:ignored];
                if (identifier.length) return identifier;
            }
        }

        NSString *flat = [value stringByTrimmingCharactersInSet:ignored];
        if (flat.length && ![flat containsString:@":"] && ![flat containsString:@"\n"]) return flat;
    }
    return nil;
}

NSInteger CCScanApplicationContainers(NSTimeInterval budget, BOOL (^visitor)(NSString *path))
{
    CCFsGetPathFn fsgetpath = CCCopyFsGetPath();
    if (!fsgetpath) return -1;

    // Use a file we own to derive a sane upper inode bound instead of walking
    // the whole volume. Placard does the same with a fixed margin.
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
    const char *root = "/var/mobile/Containers/Data/Application/";
    const size_t rootLength = strlen(root);

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
        if (strncmp(candidate, root, rootLength) != 0) continue;

        // Container directories are named by a 36-character UUID.
        const char *tail = candidate + rootLength;
        if (strlen(tail) != 36 || strchr(tail, '/')) continue;

        inspected++;
        @autoreleasepool {
            NSString *path = [NSString stringWithUTF8String:candidate];
            if (path && visitor(path)) return inspected;
        }
    }
    return inspected;
}
