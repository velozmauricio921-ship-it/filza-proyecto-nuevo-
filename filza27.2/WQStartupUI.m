//
//  WQStartupUI.m
//  FilzaSlop
//
//  Blocking launch panel: the exploit runs and every supported directory is
//  indexed before Filza's browser becomes interactive. This prevents the
//  empty-folder flash that occurs when Filza restores its own home path first.
//

#import "WQStartupUI.h"
#import "WQFilzaIntegration.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static UIWindow *gStartupWindow;
static UIWindow *gPreviousKeyWindow;
static BOOL gStartupBegan;

@interface WQStartupViewController : UIViewController
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<id> *observers;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) NSTimeInterval shownAt;
@property (nonatomic, assign) double lastProgress;
@end

@implementation WQStartupViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.035 alpha:1.0];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.shownAt = [NSDate timeIntervalSinceReferenceDate];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.105 alpha:1.0];
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:card];

    UIImage *icon = [UIImage imageNamed:@"AppIcon60x60"];
    if (!icon) icon = [UIImage imageNamed:@"AppIcon"];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.layer.cornerRadius = 16;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    [card addSubview:iconView];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Filza WQ";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"iOS 27.2 · worse_query sandbox access";
    subtitle.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [card addSubview:subtitle];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"正在启动…";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [card addSubview:self.statusLabel];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progress = 0.02;
    self.progressView.progressTintColor = [UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:1.0];
    self.progressView.trackTintColor = [UIColor colorWithWhite:0.24 alpha:1.0];
    self.progressView.layer.cornerRadius = 3;
    self.progressView.clipsToBounds = YES;
    [card addSubview:self.progressView];

    self.percentLabel = [UILabel new];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.text = @"2%";
    self.percentLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    self.percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.percentLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:self.percentLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [UIColor colorWithWhite:0.72 alpha:1.0];
    [self.spinner startAnimating];
    [card addSubview:self.spinner];

    self.detailLabel = [UILabel new];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.text = @"应用数据、App Group、系统组与扩展目录加载完成后才会进入。";
    self.detailLabel.textColor = [UIColor colorWithWhite:0.52 alpha:1.0];
    self.detailLabel.font = [UIFont systemFontOfSize:11];
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.numberOfLines = 3;
    [card addSubview:self.detailLabel];

    CGFloat cardWidth = MIN(340, self.view.bounds.size.width - 48);
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:cardWidth],

        [iconView.topAnchor constraintEqualToAnchor:card.topAnchor constant:26],
        [iconView.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:72],
        [iconView.heightAnchor constraintEqualToConstant:72],

        [title.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
        [subtitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [subtitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [self.statusLabel.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:22],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [self.progressView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:14],
        [self.progressView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [self.progressView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [self.progressView.heightAnchor constraintEqualToConstant:5],

        [self.percentLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:6],
        [self.percentLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [self.spinner.topAnchor constraintEqualToAnchor:self.percentLabel.bottomAnchor constant:12],
        [self.spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [self.detailLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:10],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [self.detailLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22],
    ]];

    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    id progressObserver = [center addObserverForName:@"WQStartupProgress"
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            [weakSelf applyProgress:notification.userInfo];
        }];
    id finishObserver = [center addObserverForName:@"WQStartupFinished"
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            [weakSelf finish];
        }];
    self.observers = @[progressObserver, finishObserver];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            if (weakSelf.finished) return;
            if (weakSelf.lastProgress < 0.9)
                weakSelf.detailLabel.text = @"目录较多时首次索引可能需要几十秒，请保持应用在前台。";
        });
}

- (void)applyProgress:(NSDictionary *)info
{
    NSNumber *progressValue = info[@"progress"];
    NSString *status = info[@"status"];
    double progress = progressValue.doubleValue;
    if (progress > self.lastProgress) self.lastProgress = progress;
    if (self.lastProgress > 1.0) self.lastProgress = 1.0;

    if (status.length) self.statusLabel.text = status;
    [self.progressView setProgress:(float)MAX(self.lastProgress, 0.02) animated:YES];
    self.percentLabel.text = [NSString stringWithFormat:@"%d%%",
        (int)round(self.lastProgress * 100.0)];
    if (progress >= 1.0) {
        [self.spinner stopAnimating];
        self.statusLabel.text = @"正在进入 Filza…";
    }
}

- (void)finish
{
    if (self.finished) return;
    self.finished = YES;
    [self applyProgress:@{ @"progress": @1.0, @"status": @"准备完成，正在进入 Filza…" }];
    [self.spinner stopAnimating];

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.shownAt;
    NSTimeInterval delay = MAX(0.35, 1.1 - elapsed);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            UIWindow *overlay = gStartupWindow;
            [UIView animateWithDuration:0.28 animations:^{
                overlay.alpha = 0.0;
            } completion:^(BOOL completed) {
                overlay.hidden = YES;
                gStartupWindow = nil;
                [UIApplication.sharedApplication setIdleTimerDisabled:NO];
                if (gPreviousKeyWindow) {
                    [gPreviousKeyWindow makeKeyWindow];
                } else {
                    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
                        if (candidate != overlay && !candidate.hidden) {
                            [candidate makeKeyWindow];
                            break;
                        }
                    }
                }
                gPreviousKeyWindow = nil;
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"WQStartupUIDidDismiss" object:nil];
                (void)weakSelf;
            }];
        });
}

- (void)dealloc
{
    for (id observer in self.observers)
        [NSNotificationCenter.defaultCenter removeObserver:observer];
}

@end

void WQStartupUIBegin(void)
{
    if (gStartupBegan) return;
    gStartupBegan = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gStartupWindow) return;
        gPreviousKeyWindow = UIApplication.sharedApplication.keyWindow;
        gStartupWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gStartupWindow.windowLevel = UIWindowLevelAlert + 10;
        gStartupWindow.backgroundColor = UIColor.blackColor;
        NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                gStartupWindow.windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        WQStartupViewController *controller = [WQStartupViewController new];
        // Force viewDidLoad so the progress notifications cannot race the
        // first report from WQFilzaStart.
        (void)controller.view;
        gStartupWindow.rootViewController = controller;
        gStartupWindow.alpha = 1.0;
        [gStartupWindow makeKeyAndVisible];
        [UIApplication.sharedApplication setIdleTimerDisabled:YES];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                WQFilzaStart();
            });
    });
}
