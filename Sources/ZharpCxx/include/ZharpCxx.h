#ifndef ZHARP_CXX_H
#define ZHARP_CXX_H

#ifdef __cplusplus
extern "C" {
#endif

/// Installs a `std::terminate` handler that writes an uncaught C++ exception's type and `what()`
/// to `path` ("<demangled type>\nfrom 0x<return address>\n<what>"), then calls the handler that was there before (the
/// Objective-C runtime's, or abort). The fatal SIGABRT that follows is reported by the signal
/// handler with the throw site's frames; the next launch names it with what this wrote.
void zharp_cxx_install_terminate_handler(const char *path);

#ifdef __cplusplus
}
#endif

#endif
