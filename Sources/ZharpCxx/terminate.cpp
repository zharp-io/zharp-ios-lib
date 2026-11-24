// Uncaught C++ exceptions, named. libc++abi calls std::terminate() from __cxa_throw when no
// handler is found, before any unwinding, so the throw site's frames are still on the stack when
// abort() raises SIGABRT (which Zharp's signal handler reports). What the signal can't carry is
// the exception itself: this handler writes its type and what() first.
#include "ZharpCxx.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cxxabi.h>
#include <exception>
#include <fcntl.h>
#include <string>
#include <typeinfo>
#include <unistd.h>

namespace {

char *gPath = nullptr;
std::terminate_handler gPrevious = nullptr;

void writeAll(int fd, const char *text, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, text, length);
        if (written <= 0) return;
        text += written;
        length -= static_cast<size_t>(written);
    }
}

void writeReport(void *from) {
    std::exception_ptr current = std::current_exception();
    if (!current || !gPath) return;
    const std::type_info *type = abi::__cxa_current_exception_type();
    const char *mangled = type ? type->name() : nullptr;
    int status = 0;
    char *demangled = mangled ? abi::__cxa_demangle(mangled, nullptr, nullptr, &status) : nullptr;
    std::string name = demangled ? demangled : (mangled ? mangled : "unknown exception");
    std::free(demangled);
    std::string what;
    try {
        std::rethrow_exception(current);
    } catch (const std::exception &e) {
        what = e.what() ? e.what() : "";
    } catch (const char *text) {
        what = text ? text : "";
    } catch (const std::string &text) {
        what = text;
    } catch (...) {
        // Not a std::exception (an Objective-C exception is reported by its own handler).
    }
    int fd = open(gPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    writeAll(fd, name.data(), name.size());
    // Where the terminate handler was called from (in libc++abi): the crash's frames up to it are
    // the abort and this handler, left out of the report.
    char line[40];
    int length = snprintf(line, sizeof line, "\nfrom 0x%llx\n", (unsigned long long)(uintptr_t)from);
    if (length > 0) writeAll(fd, line, (size_t)length);
    writeAll(fd, what.data(), what.size());
    close(fd);
}

[[noreturn]] void zharpTerminate() {
    static bool entered = false;
    if (!entered) {
        entered = true;
        try {
            writeReport(__builtin_return_address(0));
        } catch (...) {
            // Never stand in the way of the crash.
        }
    }
    if (gPrevious) gPrevious();
    std::abort();
}

}  // namespace

extern "C" void zharp_cxx_install_terminate_handler(const char *path) {
    if (gPath) return;
    gPath = strdup(path);
    gPrevious = std::set_terminate(zharpTerminate);
}
