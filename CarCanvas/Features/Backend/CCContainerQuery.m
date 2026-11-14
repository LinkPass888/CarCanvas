//
//  CCContainerQuery.m
//  CarCanvas
//

#import "CCContainerQuery.h"
#import <dlfcn.h>
#import <xpc/xpc.h>

// ContainerManager's private API. Symbols are resolved at runtime; no private
// header and no link-time dependency.
typedef void *(*CCQueryCreateFn)(void);
typedef void (*CCQuerySetClassFn)(void *, uint64_t);
typedef void (*CCQuerySetIdentifiersFn)(void *, xpc_object_t);
typedef void (*CCQuerySetFlagsFn)(void *, uint64_t);
typedef void (*CCQuerySetPartFn)(void *, uint64_t);
typedef void *(*CCQueryGetSingleResultFn)(void *);
typedef const char *(*CCObjectGetPathFn)(void *);
typedef void (*CCQueryFreeFn)(void *);
typedef void (*CCObjectFreeFn)(void *);
typedef int (*CCObjectSandboxExtensionActivateFn)(void *, const char **);

struct CCContainerAPI {
    void *handle;
    CCQueryCreateFn create;
    CCQuerySetClassFn setClass;
    CCQuerySetIdentifiersFn setIdentifiers;
    CCQuerySetFlagsFn setFlags;
    CCQuerySetPartFn setPart;
    CCQueryGetSingleResultFn singleResult;
    CCObjectGetPathFn objectGetPath;
    CCQueryFreeFn queryFree;
    CCObjectFreeFn objectFree;
    CCObjectSandboxExtensionActivateFn activate;
    BOOL valid;
};

static const struct CCContainerAPI *CCAPI(void)
{
    static struct CCContainerAPI api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                              RTLD_NOW | RTLD_LOCAL);
        if (!handle) return;
        api.handle = handle;
        api.create = (CCQueryCreateFn)dlsym(handle, "container_query_create");
        api.setClass = (CCQuerySetClassFn)dlsym(handle, "container_query_set_class");
        api.setIdentifiers = (CCQuerySetIdentifiersFn)dlsym(handle, "container_query_set_identifiers");
        api.setFlags = (CCQuerySetFlagsFn)dlsym(handle, "container_query_operation_set_flags");
        api.setPart = (CCQuerySetPartFn)dlsym(handle, "container_query_operation_set_part");
        api.singleResult = (CCQueryGetSingleResultFn)dlsym(handle, "container_query_get_single_result");
        api.objectGetPath = (CCObjectGetPathFn)dlsym(handle, "container_object_get_path");
        api.queryFree = (CCQueryFreeFn)dlsym(handle, "container_query_free");
        api.objectFree = (CCObjectFreeFn)dlsym(handle, "container_object_free");
        api.activate = (CCObjectSandboxExtensionActivateFn)dlsym(handle, "container_object_sandbox_extension_activate");
        api.valid = api.create && api.setClass && api.setIdentifiers && api.singleResult &&
                    api.objectGetPath && api.activate;
    });
    return &api;
}

BOOL CCContainerQueryIsAvailable(void)
{
    return CCAPI()->valid;
}

typedef void (*CCQueryIterateFn)(void *, bool (^)(void *));

/// Enumerates every container ContainerManager will hand out, by walking the
/// classes the way WQFiles does. The bundle-id single-result query needs an
/// identity this build does not have, which is why it returns nothing.
NSArray<NSDictionary<NSString *, NSString *> *> *CCContainerEnumerate(void)
{
    const struct CCContainerAPI *api = CCAPI();
    if (!api->handle) return @[];

    CCQueryIterateFn iterate =
        (CCQueryIterateFn)dlsym(api->handle, "container_query_iterate_results_sync");
    if (!iterate || !api->create || !api->setClass || !api->objectGetPath) return @[];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (uint64_t cls = 1; cls <= 14; cls++) {
        void *query = api->create();
        if (!query) continue;
        api->setClass(query, cls);
        @try {
            iterate(query, ^bool(void *object) {
                const char *path = object ? api->objectGetPath(object) : NULL;
                if (!path || !path[0]) return true;
                NSString *value = [NSString stringWithUTF8String:path];
                if (value.length == 0 || [seen containsObject:value]) return true;
                [seen addObject:value];

                // Read the identifier straight off the container directory.
                NSString *metadata = [value stringByAppendingPathComponent:
                                      @".com.apple.mobile_container_manager.metadata.plist"];
                NSString *identifier = nil;
                NSData *data = [NSData dataWithContentsOfFile:metadata];
                if (data) {
                    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                                        options:0
                                                                         format:NULL
                                                                          error:NULL];
                    if ([plist isKindOfClass:[NSDictionary class]]) {
                        id raw = [(NSDictionary *)plist objectForKey:@"MCMMetadataIdentifier"];
                        if ([raw isKindOfClass:[NSString class]]) identifier = raw;
                    }
                }
                if (identifier.length) {
                    @synchronized (results) {
                        [results addObject:@{@"path": value, @"identifier": identifier}];
                    }
                }
                return true;
            });
        } @catch (__unused NSException *exception) {
            // A class that refuses the query is simply skipped.
        }
        if (api->queryFree) api->queryFree(query);
    }
    return results;
}

int64_t CCConsumeContainerToken(NSString *token)
{
    if (token.length == 0) return -255;
    typedef int64_t (*CCConsumeFn)(const char *);
    static CCConsumeFn consume;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        consume = (CCConsumeFn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    });
    if (!consume) return -254;
    return consume(token.UTF8String);
}

// class 7 == app bundle/container identifier query; this is the value the
// original binary and worse_query both use for app identifiers.
static void *CCRunQuery(NSString *bundleID, void **outObject)
{
    const struct CCContainerAPI *api = CCAPI();
    if (!api->valid || bundleID.length == 0) return NULL;

    void *query = api->create();
    if (!query) return NULL;

    xpc_object_t identifier = xpc_string_create(bundleID.UTF8String);
    api->setClass(query, 7);
    api->setIdentifiers(query, identifier);
    api->setPart(query, 1);          // 1 == the data container itself
    api->setFlags(query, 0x0000008000000000ULL);

    void *object = api->singleResult(query);
    api->queryFree(query);
    if (outObject) *outObject = object;
    return object;
}

NSString *CCContainerPathForBundleID(NSString *bundleID)
{
    void *object = NULL;
    if (!CCRunQuery(bundleID, &object) || !object) return nil;

    const struct CCContainerAPI *api = CCAPI();
    const char *path = api->objectGetPath(object);
    NSString *result = path ? [NSString stringWithUTF8String:path] : nil;
    if (api->objectFree) api->objectFree(object);
    return result.length ? result : nil;
}

/// The whole usable-unit: resolve the container by bundle id and hand back
/// BOTH its path and the sandbox extension token ContainerManager issued for
/// it. This is the original app's mechanism for reaching another app's data.
BOOL CCContainerLookup(NSString *bundleID,
                       NSString **outPath,
                       NSString **outToken)
{
    const struct CCContainerAPI *api = CCAPI();
    if (!api->valid || bundleID.length == 0) return NO;

    void *object = NULL;
    if (!CCRunQuery(bundleID, &object) || !object) return NO;

    const char *path = api->objectGetPath(object);
    if (path && outPath) *outPath = [NSString stringWithUTF8String:path];

    const char *token = NULL;
    int rc = api->activate(object, &token);
    if (rc == 0 && token && outToken) *outToken = [NSString stringWithUTF8String:token];

    if (api->objectFree) api->objectFree(object);
    return (rc == 0 && token != NULL);
}
