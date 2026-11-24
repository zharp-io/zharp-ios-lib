#ifndef NATIVE_E2E_H
#define NATIVE_E2E_H

#ifdef __cplusplus
extern "C" {
#endif

/// C: applies a discount to an order that was never loaded (a null pointer write).
void native_e2e_null_write(void);
/// C++: totals a cart whose second price isn't a number; std::runtime_error, never caught.
void native_e2e_cxx_throw(void);

#ifdef __cplusplus
}
#endif

#endif
