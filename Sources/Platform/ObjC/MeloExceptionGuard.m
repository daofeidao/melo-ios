#import "MeloExceptionGuard.h"

BOOL melo_try(void (^block)(void), NSError **error) {
    @try {
        if (block) { block(); }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] =
                [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"-"];
            NSArray *symbols = [exception callStackSymbols];
            if (symbols.count > 0) {
                info[@"stack"] = [symbols componentsJoinedByString:@"\n"];
            }
            *error = [NSError errorWithDomain:@"com.daofeidao.melo.ExceptionGuard"
                                         code:1
                                     userInfo:info];
        }
        return NO;
    }
}
