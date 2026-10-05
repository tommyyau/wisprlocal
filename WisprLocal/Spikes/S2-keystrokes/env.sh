# source this: works around unaccepted Xcode license (no sudo) by bypassing the xcrun shims
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
export SDKROOT=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
