#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the in-process WebDAV server. Filza normally starts a root launch
/// daemon for this; on a normally signed app the daemon path is unavailable,
/// so this server lives in the Filza process and uses the active worse_query
/// extensions.
FOUNDATION_EXPORT BOOL WQWebDAVStart(NSString *_Nullable *_Nullable error);
FOUNDATION_EXPORT void WQWebDAVStop(void);
FOUNDATION_EXPORT BOOL WQWebDAVIsRunning(void);
FOUNDATION_EXPORT NSString *WQWebDAVURL(void);
FOUNDATION_EXPORT NSInteger WQWebDAVPort(void);

NS_ASSUME_NONNULL_END
