// example/cpp/hello/analyze_hello.cpp - C++ consumer of libvizg.a via C ABI.
// Links against the same static archive; only difference from the C example is
// we include vizg.h inside `extern "C"` and use std::cout/std::string for nicer output.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <vector>
#include <iomanip>
#include "../../../Lib/vizg.h"    // public C ABI header (declare, do not link against the Zig source)

static std::string slurp(const char *path) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error(std::string("cannot open: ") + path);
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}

static void print_result(Vizg_Result *r, const char *label = "") {
    if (!r) { std::cerr << "vizg_analyze_file returned null\n"; std::exit(1); }
    std::cout << "=== vizg C-ABI example (C++) ===\n";
    if (*label) std::cout << "Source: " << label << '\n';
    std::cout << "Bytes : " << r->token_count + r->diagnostic_count
              << " total tokens+diagnostics\n"
              << " Tokens          : " << r->token_count      << "\n"
              << " Diagnostics     : " << r->diagnostic_count  << "\n";

    if (r->tokens_ptr && r->token_count) {
        auto *toks = static_cast<const Vizg_Token *>(r->tokens_ptr);
        size_t n = std::min(r->token_count, (uint32_t)5);
        std::cout << "\nFirst " << n << " token(s):\n";
        for (size_t i = 0; i < n; ++i) {
            std::string lex(toks[i].lexeme_ptr, toks[i].lexeme_len);
            if (lex.size() > 40) lex.resize(39);
            std::cout << "  [" << i << "] " << std::left << std::setw(42) << lex.c_str()
                      << " kind=" << static_cast<int>(toks[i].kind) << "\n";
        }
    }

    if (r->diagnostics_ptr && r->diagnostic_count) {
        auto *d = static_cast<const Vizg_Diagnostic *>(r->diagnostics_ptr);
        std::cout << "\nDiagnostics:\n";
        for (uint32_t i = 0; i < r->diagnostic_count; ++i) {
            std::string msg(d[i].message_ptr, d[i].message_len);
            std::cout << "  [" << i << "] sev=" << static_cast<int>(d[i].severity)
                      << " code=" << static_cast<int>(d[i].code)
                      << " phase=" << static_cast<int>(d[i].phase)
                      << " msg=\"" << msg << "\""
                      << " span=+" << d[i].span.start_offset << ".." << d[i].span.end_offset << "\n";
        }
    }
    vizg_free_result(r);
}

int main(int argc, char **argv) {
    Vizg_Result *result = nullptr;
    std::string src;
    if (argc > 1 && strcmp(argv[1], "-") != 0) {
        src = slurp(argv[1]);
        result = vizg_analyze_file(nullptr, 0, src.data(), src.size());
        print_result(result, argv[1]);
    } else {
        std::vector<char> buf((std::istreambuf_iterator<char>(std::cin)),
                               std::istreambuf_iterator<char>());
        buf.push_back('\0');
        result = vizg_analyze_file(nullptr, 0, buf.data(), buf.size() - 1);
        print_result(result, "stdin");
    }
    return 0;
}
