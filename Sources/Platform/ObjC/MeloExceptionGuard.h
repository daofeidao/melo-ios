#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跑一段可能抛 ObjC 异常的代码。
///
/// 为什么需要它：Swift 的 `try?` 只能接 Swift error，接不住 ObjC 的
/// `NSException`（AVFoundation / MediaPlayer / MediaRemote 这类框架抛的都是
/// 这种）。一旦抛出就是「Terminating app due to uncaught exception」，进程直接
/// 没了，连一句像样的报错都看不到。Mac（Catalyst）上表现尤其明显——iOS 上
/// 能容忍的调用，在 macOS 侧的实现里可能直接抛。
///
/// 这里用 ObjC 的 @try/@catch 把它接住，返回 NO 并把异常名、原因、调用栈
/// 塞进 NSError，调用方写进运行日志，然后降级继续（例如不带私有 header 重试）。
///
/// @return YES 表示正常跑完；NO 表示抛了异常（error 里是细节）。
BOOL melo_try(void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
