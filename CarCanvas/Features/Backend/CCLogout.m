//
//  CCLogout.m
//  CarCanvas
//

#import "CCLogout.h"
#import <spawn.h>
#import <sys/wait.h>
#import <errno.h>

extern char **environ;

CCLogoutResult CCLogoutRequest(NSString **detail)
{
    // The only documented way for a non-root process to end the console
    // session is to ask launchd. It is outside the app sandbox, so a normal
    // IPA build will usually get EPERM here; the caller must surface that
    // instead of pretending the device is logging out.
    const char *argv[] = { "/bin/launchctl", "logout", NULL };

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    if (rc != 0) {
        if (detail) *detail = [NSString stringWithFormat:@"posix_spawn failed (%d)", rc];
        return CCLogoutResultUnavailable;
    }

    int status = 0;
    pid_t waited = waitpid(pid, &status, 0);
    if (waited < 0) {
        if (detail) *detail = [NSString stringWithFormat:@"waitpid failed (%d)", errno];
        return CCLogoutResultUnavailable;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        if (detail) *detail = @"launchctl logout accepted";
        return CCLogoutResultRequested;
    }

    if (detail) {
        *detail = WIFEXITED(status)
            ? [NSString stringWithFormat:@"launchctl exited with %d (sandbox or permission denied)",
                                         WEXITSTATUS(status)]
            : [NSString stringWithFormat:@"launchctl terminated by signal %d", WTERMSIG(status)];
    }
    return CCLogoutResultDenied;
}
