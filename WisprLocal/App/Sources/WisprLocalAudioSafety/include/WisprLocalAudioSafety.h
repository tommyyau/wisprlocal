#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVAudioEngine can raise NSException when hardware disappears between format validation
/// and tap installation. Return an ordinary error; the caller must discard the failed graph.
BOOL WLInstallTapAndPrepare(AVAudioEngine *engine, AVAudioNode *node,
                           AVAudioNodeTapBlock block, NSError * _Nullable *error);
BOOL WLPrepareAudioEngine(AVAudioEngine *engine, NSError * _Nullable *error);

NS_ASSUME_NONNULL_END
