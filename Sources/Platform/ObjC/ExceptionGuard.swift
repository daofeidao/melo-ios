import Foundation

/// ObjC 异常护栏的 Swift 侧封装。
///
/// 用法：把「可能抛 NSException 的调用」塞进 `ExceptionGuard.run`。抛了不崩，
/// 而是把异常名、原因、调用栈写进运行日志，并返回 false，调用方可以降级重试。
enum ExceptionGuard {

    @discardableResult
    static func run(_ label: String, _ block: @escaping () -> Void) -> Bool {
        var error: NSError?
        let ok = melo_try(block, &error)
        if !ok {
            let reason = error?.localizedDescription ?? "-"
            Diagnostics.mark("💥 \(label) 抛异常：\(reason)")
            if let stack = (error?.userInfo["stack"] as? String) {
                for line in stack.split(separator: "\n").prefix(16) {
                    Diagnostics.mark("   \(line)")
                }
            }
        }
        return ok
    }
}
