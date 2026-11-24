#include "native.h"

#include <stddef.h>

struct order {
    int id;
    int total;
};

/* Not inlined, so the crash is in a frame of its own: orders.c, apply_discount. */
__attribute__((noinline)) static void apply_discount(struct order *order, int percent) {
    order->total -= order->total * percent / 100;
}

void native_e2e_null_write(void) {
    struct order *volatile loaded = NULL; /* volatile: the optimizer can't see it's NULL */
    apply_discount(loaded, 10);
}
