#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shows the blocking startup panel and starts the worse_query pipeline.
/// The panel dismisses when @"WQStartupFinished" is posted, then posts
/// @"WQStartupUIDidDismiss" so the browser can jump to the populated root.
FOUNDATION_EXPORT void WQStartupUIBegin(void);

NS_ASSUME_NONNULL_END
