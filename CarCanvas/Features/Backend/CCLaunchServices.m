//
//  CCLaunchServices.m
//  CarCanvas
//

#import "CCLaunchServices.h"
#import <objc/message.h>
#import <objc/runtime.h>

BOOL CCLSIsAvailable(void)
{
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        available = cls != Nil && [cls respondsToSelector:NSSelectorFromString(@"defaultWorkspace")];
    });
    return available;
}

/// One proxy's (path, bundleID) pair, or nil.
static void CCConsiderProxy(id proxy,
                            NSMutableDictionary<NSString *, NSString *> *out)
{
    if (!proxy) return;
    SEL containerSel = NSSelectorFromString(@"dataContainerURL");
    SEL idSel = NSSelectorFromString(@"bundleIdentifier");
    if (![proxy respondsToSelector:containerSel] || ![proxy respondsToSelector:idSel]) return;

    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    @try {
        NSURL *url = send(proxy, containerSel);
        NSString *bundleID = send(proxy, idSel);
        if (![url isKindOfClass:[NSURL class]] || ![bundleID isKindOfClass:[NSString class]]) return;
        if (url.path.length == 0 || bundleID.length == 0) return;
        if (!out[url.path]) out[url.path] = bundleID;
    } @catch (__unused NSException *exception) {
        // LaunchServices can throw on some builds; treat it as "not found".
    }
}

NSDictionary<NSString *, NSString *> *CCLSAllContainers(void)
{
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    if (!CCLSIsAvailable()) return result;

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    @try {
        id workspace = send((id)cls, NSSelectorFromString(@"defaultWorkspace"));
        if (!workspace) return result;

        SEL allApps = NSSelectorFromString(@"allInstalledApplications");
        if ([workspace respondsToSelector:allApps]) {
            NSArray *apps = send(workspace, allApps);
            if ([apps isKindOfClass:[NSArray class]]) {
                SEL pluginsSel = NSSelectorFromString(@"plugInKitPlugins");
                for (id app in apps) {
                    CCConsiderProxy(app, result);
                    // Extensions have their own containers.
                    if ([app respondsToSelector:pluginsSel]) {
                        NSArray *plugins = send(app, pluginsSel);
                        if ([plugins isKindOfClass:[NSArray class]]) {
                            for (id plugin in plugins) CCConsiderProxy(plugin, result);
                        }
                    }
                }
            }
        }

        // Some builds only answer this one.
        if (result.count == 0) {
            SEL allInstalled = NSSelectorFromString(@"allApplications");
            if ([workspace respondsToSelector:allInstalled]) {
                NSArray *apps = send(workspace, allInstalled);
                if ([apps isKindOfClass:[NSArray class]]) {
                    for (id app in apps) CCConsiderProxy(app, result);
                }
            }
        }
    } @catch (__unused NSException *exception) {
        // Same as above: an unavailable API is not an error we can act on.
    }
    return result;
}

NSString *CCLSContainerPathForBundleID(NSString *bundleID)
{
    if (bundleID.length == 0) return nil;
    NSDictionary<NSString *, NSString *> *all = CCLSAllContainers();
    for (NSString *path in all) {
        if ([all[path] isEqualToString:bundleID]) return path;
    }
    return nil;
}
