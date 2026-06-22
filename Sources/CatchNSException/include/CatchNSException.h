#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try/@catch` and returns the
/// caught `NSException`, or `nil` if it completed normally. Swift's
/// `do/catch` only intercepts Swift `Error`s; some Cocoa calls (e.g.
/// `-[AVAudioPlayerNode play]`) still report transient failure by
/// raising an ObjC exception, which otherwise unwinds past Swift and
/// terminates the process. The block runs synchronously on the caller's
/// thread, so it may capture and touch caller state.
NSException *_Nullable ContermCatchNSException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
