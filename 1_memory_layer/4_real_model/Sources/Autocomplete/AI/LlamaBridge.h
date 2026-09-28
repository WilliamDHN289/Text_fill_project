#ifndef LlamaBridge_h
#define LlamaBridge_h

#include "llama.h"

#include <CoreFoundation/CoreFoundation.h>

// Private HIServices text-marker C API: decompose an AXTextMarkerRange into its
// start/end AXTextMarker objects. No AX attribute exists for this. Used to read the
// caret in WebKit document-level web areas (e.g. Apple Mail's compose body), which
// return kAXErrorNoValue for the integer AXSelectedTextRange. Symbols verified
// present in ApplicationServices (HIServices).
CFTypeRef _Nullable AXTextMarkerRangeCopyStartMarker(CFTypeRef _Nonnull range);
CFTypeRef _Nullable AXTextMarkerRangeCopyEndMarker(CFTypeRef _Nonnull range);

#endif /* LlamaBridge_h */
