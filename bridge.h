// Exposes the whisper C API to Swift via `swiftc -import-objc-header`.
// Replaces a module map / wrapper target: no `import` needed in the Swift sources.
#include "vendor/whisper.cpp/include/whisper.h"
