#import "WisprLocalAudioSafety.h"

static void WLSetAudioError(NSError **error) {
    if (error) {
        *error = [NSError errorWithDomain:@"WisprLocal.AudioGraph" code:1
                                userInfo:@{NSLocalizedDescriptionKey:
            @"The microphone changed while starting. Try recording again."}];
    }
}

BOOL WLInstallTapAndPrepare(AVAudioEngine *engine, AVAudioNode *node,
                           AVAudioNodeTapBlock block, NSError **error) {
    @try {
        // nil preserves the node's native format instead of imposing a stale device format.
        [node installTapOnBus:0 bufferSize:1024 format:nil block:block];
        [engine prepare];
        return YES;
    } @catch (NSException *exception) {
        WLSetAudioError(error);
        return NO;
    }
}

BOOL WLPrepareAudioEngine(AVAudioEngine *engine, NSError **error) {
    @try {
        [engine prepare];
        return YES;
    } @catch (NSException *exception) {
        WLSetAudioError(error);
        return NO;
    }
}
