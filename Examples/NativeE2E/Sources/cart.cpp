#include "native.h"

#include <stdexcept>
#include <string>
#include <vector>

namespace shop {

__attribute__((noinline)) int parse_price(const std::string &text) {
    for (char c : text) {
        if (c < '0' || c > '9') throw std::runtime_error("Price is not a number: \"" + text + "\"");
    }
    return std::stoi(text);
}

__attribute__((noinline)) int cart_total(const std::vector<std::string> &prices) {
    int total = 0;
    for (const auto &price : prices) total += parse_price(price);
    return total;
}

}  // namespace shop

extern "C" void native_e2e_cxx_throw(void) {
    std::vector<std::string> prices{"12", "twelve"};
    volatile int total = shop::cart_total(prices);
    (void)total;
}
