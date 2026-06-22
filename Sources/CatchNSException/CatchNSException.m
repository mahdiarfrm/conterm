#import "CatchNSException.h"

NSException *_Nullable ContermCatchNSException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
