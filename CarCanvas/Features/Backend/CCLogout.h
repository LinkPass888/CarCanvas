//
//  CCLogout.h
//  CarCanvas
//
//  Ends the current user session ("log out") so SpringBoard relaunches and
//  CarPlay re-reads the wallpaper cache. A sandboxed app cannot respring the
//  device directly; the supported path is asking launchd to log the console
//  user out, which is what this wrapper attempts.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CCLogoutResult) {
    CCLogoutResultRequested = 0,   // launchctl accepted the request
    CCLogoutResultDenied,          // sandbox/permission refused it
    CCLogoutResultUnavailable      // launchctl could not be reached at all
};

/// Attempts to log out the current console user. Never throws, never blocks
/// for long, and reports exactly what happened so the UI can be honest about
/// whether the session will actually end.
CCLogoutResult CCLogoutRequest(NSString * _Nullable * _Nullable detail);

NS_ASSUME_NONNULL_END
